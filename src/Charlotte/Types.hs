{-# LANGUAGE DeriveDataTypeable #-}
module Charlotte.Types (
    Meta
  , Flag
  , JobQueue(..)
  -- , jobQueueProducer
  , newJobQueueIO
  , writeJobQueue
  , readJobQueue
  , isEmptyJobQueue
  , isActiveJobQueue
  , taskCompleteJobQueue
) where
import           Data.Dynamic               (Dynamic)
import           Data.Map.Strict            (Map)
import           Control.Concurrent.STM
import           Data.Typeable              (Typeable)

type Meta = Map String Dynamic
type Flag = String


data JobQueue a = JobQueue {-# UNPACK #-} !(TQueue a)
                           {-# UNPACK #-} !(TVar Int)
  deriving Typeable

newJobQueueIO :: IO (JobQueue a)
newJobQueueIO = do
  queue   <- newTQueueIO
  active  <- newTVarIO (0 :: Int)
  return (JobQueue queue active)

readJobQueue :: JobQueue a -> STM a
readJobQueue (JobQueue queue _ ) = readTQueue queue

writeJobQueue :: JobQueue a-> a -> STM ()
writeJobQueue (JobQueue queue active) a = do
  writeTQueue queue a
  modifyTVar' active succ

taskCompleteJobQueue :: JobQueue a -> STM ()
taskCompleteJobQueue (JobQueue _ active) = modifyTVar' active pred

isEmptyJobQueue :: JobQueue a -> STM Bool
isEmptyJobQueue (JobQueue queue _) = isEmptyTQueue queue

isActiveJobQueue :: JobQueue a -> STM Bool
isActiveJobQueue (JobQueue _ active) = do
  c <- readTVar active
  return (c /= 0)
