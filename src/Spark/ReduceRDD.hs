{-# LANGUAGE KindSignatures, ScopedTypeVariables, TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, GADTs #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}

-- {-# LANGUAGE MultiParamTypeClasses #-}
-- {-# LANGUAGE TemplateHaskell #-}
-- {-# LANGUAGE KindSignatures #-}
-- {-# LANGUAGE RankNTypes #-}

module Spark.ReduceRDD

where

    
import Spark.Context
import Spark.RDD
import Spark.SeedRDD hiding (__remoteTable)
import Spark.Block

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Control.Distributed.Process.Serializable
import qualified Data.Map as M
import Data.Typeable
import GHC.Generics
import Data.Binary
import Control.Monad

data ReduceRDD a k v = ReduceRDD { _baseM :: a (k,v)
                                 , _cFun  :: Closure (v -> v -> v)
                                 , _pFun  :: Closure (k -> Int)
                                 , _tdict :: Static (SerializableDict [(k,v)])
                                 }


-- | ReduceRDD takes a base RDD that produces a pair, and reduces it per key
-- ReduceRDD uses a combining function and every block is reduced
-- using combining function. The reduction happens in two steps. In
-- the first step, reduction is done per block. In the next iteration,
-- the hashing (partitioning) function is applied to shuffle the
-- locally reduced data to only one node. Further reduction is done
-- per such hashed block. 
reduceRDD :: (RDD a (k,v), Ord k, Serializable k, Serializable v) =>
             Context
          -> a (k,v)
          -> Static (SerializableDict [(k,v)] )
          -> Closure (v -> v -> v)
          -> Closure (k -> Int)
          -> ReduceRDD a k v
reduceRDD sc base dict combiner partitioner =
    ReduceRDD base combiner partitioner dict


data FetchPartition = FetchPartition Int ProcessId
                      deriving (Typeable, Generic)

instance Binary FetchPartition

sendKV :: SerializableDict [(k,v)] -> ProcessId -> [(k,v)] -> Process ()
sendKV SerializableDict = send

data OrdDict a where
    OrdDict :: forall a . Ord a => OrdDict a

rFromList :: OrdDict k -> (v -> v -> v) -> [(k,v)] -> M.Map k v
rFromList OrdDict =  M.fromListWith

rUnion :: OrdDict k -> (v -> v -> v) -> M.Map k v -> M.Map k v -> M.Map k v
rUnion OrdDict = M.unionWith

reduceStep1 :: OrdDict k
            -> SerializableDict [(k,v)]
            -> (Int, ProcessId)
            -> (v -> v -> v)
            -> (k -> Int)
            -> Process ()
reduceStep1 dictk dictkv (n, pid) combiner partitioner = do
  thispid <- getSelfPid
  sendFetch dictkv pid (Fetch thispid)
  dt <- receiveWait [ matchSeed dictkv $ \xs -> return (Just xs)
                    , match $ \() -> return Nothing
                    ]
  -- Reduction step 1, locally reduce the block
  let mp = case dt of
             Just xs -> rFromList dictk combiner xs
             Nothing -> M.empty

  -- Serve all the keys for given partition.
  receiveWait [ match $ \(FetchPartition p sid) -> do
                  let kvs = M.toList $ M.filterWithKey (\k _ -> partitioner k `mod` n == p ) mp
                  sendKV dictkv sid kvs
              , match $ \() -> return () 
              ]

expectKV :: SerializableDict [(k,v)] -> Process [(k,v)]
expectKV SerializableDict = expect

matchKV :: SerializableDict [(k,v)] -> ([(k,v)] -> Process b) -> Match b
matchKV SerializableDict = match

-- | Reduction Step 2 : Get all the 
reduceStep2 :: OrdDict k
            -> SerializableDict [(k,v)]
            -> (Int, [(Int, ProcessId)]) -- ^ Partition and all the
                                         -- processes in reduction
                                         -- step 1
            -> (v -> v -> v)       -- ^ Combiner function
            -> Process ()
reduceStep2 dictk dictkv (p, ips) combiner = do
  thispid <- getSelfPid
  let kvreduce mp (i,pid) = do
        send pid (FetchPartition p thispid)
        vs <- receiveWait [ matchKV dictkv $ \kvs -> return kvs ]
        let mp1 = rFromList dictk combiner vs
        return $ rUnion dictk combiner mp mp1
  reduced <- foldM kvreduce M.empty ips

  -- Now that we have
  let kvs = M.toList reduced
  receiveWait [ matchFetch dictkv $ \(Fetch pid) -> do
                  sendSeed dictkv pid kvs
                  return ()
              , match $ \() -> return ()
              ]

partitionedPids :: SerializableDict (Int, [(Int, ProcessId)])
partitionedPids = SerializableDict

partitionPair :: SerializableDict (Int, ProcessId)
partitionPair = SerializableDict

remotable [ 'reduceStep1, 'reduceStep2, 'partitionedPids, 'partitionPair ]

reduceStep1Closure :: (Ord k, Serializable k, Serializable v) =>
                      Static (OrdDict k)
                   -> Static (SerializableDict [(k,v)])
                   -> (Int, ProcessId)
                   -> Closure (v -> v -> v)
                   -> Closure (k -> Int)
                   -> Closure (Process ())
reduceStep1Closure dictk dictkv ipid combiner partitioner =
    closure decoder (encode ipid) `closureApply` combiner `closureApply` partitioner
        where
          decoder = ( $(mkStatic 'reduceStep1) `staticApply` dictk `staticApply` dictkv )
                    `staticCompose` staticDecode $(mkStatic 'partitionPair)

reduceStep2Closure :: (Ord k, Serializable k, Serializable v) =>
                      Static (OrdDict k)
                   -> Static (SerializableDict [(k,v)])
                   -> (Int, [(Int, ProcessId)])
                   -> Closure (v -> v -> v)
                   -> Closure (Process ())
reduceStep2Closure dictk dictkv ipid combiner =
    closure decoder (encode ipid) `closureApply` combiner 
        where
          decoder = ( $(mkStatic 'reduceStep2) `staticApply` dictk `staticApply` dictkv )
                    `staticCompose` staticDecode $(mkStatic 'partitionedPids)

