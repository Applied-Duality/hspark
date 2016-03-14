{-# LANGUAGE DeriveGeneric #-}
module Spark.Partition where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Static
import qualified Data.Map as M
import Control.Monad
import Data.Typeable
import Data.Binary
import GHC.Generics


-- | Partitions represent a data encapsulated in a process
-- The data can be requested by requesting the process.

newtype Partitions a = Partitions { _blocks :: M.Map Int ProcessId }

-- | Request the data from a process
newtype RequestData = RequestData ProcessId
    deriving (Typeable, Generic)

instance Binary RequestData
    
-- | Send the data back
newtype PartitionData a = PD a
    deriving (Typeable, Generic)

instance Serializable a => Binary (PartitionData a)

-- | Stage the data in a process
-- Stage the data in the process such that it can be fetched by an
-- appropriate message. 

stage :: Serializable a => ProcessId -> a -> Process ()
stage master dt = do
  pid <- getSelfPid
  say "Data received .."
  send master pid

  let sendData (RequestData pid)= send pid (PD dt)

  -- Be ready to serve the data
  forever $ receiveWait [ match sendData ]


-- | Process data with a closure map

mapStage :: (Serializable a, Serializable b)
            => Closure (ProcessId, ProcessId) -> Closure (a -> b)  -> Process ()
mapStage cs cf = do
  (master, source) <- unClosure cs
  pid <- getSelfPid
  send source (RequestData pid)
  -- Wait till we receive the data
  let receiveData (PD xs) = return xs
  dt <- receiveWait [ match receiveData ]
  f  <- unClosure cf
  stage master (f dt)
  

-- | Process data, combine it with IO closure map.

mapStageIO :: (Serializable a, Serializable b)
           => Closure (ProcessId, ProcessId)
           -> Closure (a -> IO b)
           -> Process ()
mapStageIO cs cf = do
  (master, source) <- unClosure cs
  pid <- getSelfPid
  send source (RequestData pid)
  -- Wait till we receive the data
  let receiveData (PD xs) = return xs
  dt <-  receiveWait [ match receiveData ]
  f  <-  unClosure cf
  pdt <- liftIO $ f dt
  stage master pdt
  
