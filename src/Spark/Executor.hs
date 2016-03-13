module Spark.Executor where


import Spark.Context
import Spark.RDD
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Spark.Pure.Exec
    
-- | Process RDD and collect the data
-- This is where all the processing is initiated. The RDD is reduced
-- to number of stages. Typically these stages are 'mapping' and
-- 'reducing'. They are characterized by the fact that mapping can be
-- pipelined, whereas reduce stage typically would need a shuffle in
-- between. 
collect :: (RDD a b, Serializable b) => Context -> a b -> IO [b]
collect = undefined
-- collect sc rdd = case sc of
--                    Pure -> executePure rdd
--                    Distributed nodes -> executeDistributed nodes rdd


executeDistributed :: (RDD a b, Serializable b) => Context -> [NodeId] -> a b -> IO [b]
executeDistributed = undefined
