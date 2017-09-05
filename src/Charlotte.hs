{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
module Charlotte (
    SpiderDefinition(..)
  , Result(..)
  , Response
  , Request
  , runSpider
  , Request.mkRequest
  --TODO move to a new home
  , JobQueue(..)
  , jobQueueProducer
  , newJobQueueIO
  , writeJobQueue
  , readJobQueue
  , isEmptyJobQueue
  , taskCompleteJobQueue
) where
import           Prelude                    (Bool (..), Either (..), Foldable,
                                             Functor, IO, Maybe (..), Show (..),
                                             String, Traversable, Int, fmap, filter, flip,
                                             head, const,
                                             length, mapM_, not, putStr, putStrLn, foldMap, id,
                                             print, replicate, return, seq, sequence, ($),
                                             succ, pred, (==), (>), (&&),
                                             ($!), (.), (/=), (<$>), (>>))

import Debug.Trace
import Data.Foldable as F
import           Control.Monad              (when, unless, mapM, forever, replicateM_, void, (>>=))
import           Data.Either                (isLeft, isRight, rights)
import           Data.Maybe (fromJust, isNothing, fromMaybe, mapMaybe)
import Control.Category (Category)
import Control.Concurrent (threadDelay, forkIO, MVar, newMVar, readMVar, putMVar, tryReadMVar, tryPutMVar)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import           Data.Semigroup             ((<>))
import qualified Data.Set                   as S
import           Data.Typeable              (Typeable)
import qualified Network.HTTP.Client        as C
import           Network.HTTP.Client.TLS    (tlsManagerSettings)
import qualified Network.URI as URI
import Network.HTTP.Types as NT

import           Control.Concurrent.STM
import qualified Control.Exception          as E
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Data.Machine
import           Data.Machine.Concurrent    (scatter, (>~>))
import Control.Concurrent.Async (async, wait)
import           Data.Machine.Regulated     (regulated)
-- import qualified Network.HTTP.Types         as CT
-- import           Data.Text.Encoding.Error (lenientDecode)
-- import           Data.Text.Lazy.Encoding  (decodeUtf8With)
import qualified Data.Text                as T
-- import           Text.Taggy.Lens          (allNamed, attr, html)
import Charlotte.Response (Response)
import Charlotte.Request (Request)
import qualified Charlotte.Response as Response
import qualified Charlotte.Request as Request


data Result a b =
    Request (a Request)
  | Item  b

instance (Show (a Request), Show b) => Show (Result a b) where
  show (Request r) = "Result Request (" <> show r <> ")"
  show (Item i)    = "Result " <> show i

resultIsItem,resultIsRequest :: Result a b -> Bool
resultIsItem (Item _) = True
resultIsItem _        = False
resultIsRequest = not . resultIsItem

resultGetRequest :: Result a b -> Maybe (a Request)
resultGetRequest (Request r) = Just r
resultGetRequest _           = Nothing

resultGetItem  :: Result a b -> Maybe b
resultGetItem  (Item r) = Just r
resultGetItem _         = Nothing

data SpiderDefinition a b = SpiderDefinition {
    _name      :: String
  , _startUrl  :: a String                                   -- source
  , _extract   :: a Response -> [Result a b]               -- extract
  , _transform :: Maybe (b -> IO b)   -- transform
  , _load      :: Maybe (b -> IO ())                -- load
}

------ new stuff -----------
data JobQueue a = JobQueue {-# UNPACK #-} !(TQueue a)
                           {-# UNPACK #-} !(TVar Int)
  deriving Typeable



log :: (MonadIO m) => String -> m ()
log str = liftIO $ putStrLn str

-- jobQueueProducer :: JobQueue a -> PlanT k a IO ()
jobQueueProducer :: JobQueue a -> SourceT IO a
jobQueueProducer q = construct go
  where
    go = do
      active <- liftIO $ atomically $ isActiveJobQueue q
      unless active (log $ "jobQueueProducer: stopping active is False")
      unless active stop
      cnt <- liftIO $ atomically $ jobQueueActiveCount q
      log $ "jobQueueProducer: readJobQueue (" <> show cnt <> ") active jobs"
      isEmpty <- liftIO $ atomically $ isEmptyJobQueue q
      log $ "jobQueueProducer: readJobQueue isEmpty: " <> show isEmpty
      unless isEmpty $ do
        r <- liftIO $ atomically $ readJobQueue q
        log $ "jobQueueProducer: got value yielding"
        yield r
      when isEmpty $  do
        log $ "jobQueueProducer: isEmpty. sleeping a bit."
        liftIO $ threadDelay 2000000
      -- when (isEmpty && (cnt == 1)) $ do
      --   log $ "jobQueueProducer: isEmpty with a active count of 1"
      --   r <- liftIO $ atomically $ readJobQueue q
      --   log $ "jobQueueProducer: got value yielding"
      --   yield r
      go




    -- yieldNextThing = do
    --   r <- trace ("yield next thing") liftIO $ atomically $ readJobQueue q
    --   yield r




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

jobQueueActiveCount :: JobQueue a -> STM Int
jobQueueActiveCount (JobQueue _ active) = readTVar active

-- mkWorker :: (Traversable t, Category k) => C.Manager -> MachineT IO (k (t Request)) (t (Either String Response))
-- mkWorker manager = autoM $ worker manager
--   where
--     worker :: Traversable t => C.Manager -> t Request -> IO (t (Either String Response))
--     worker manager r = sequence $ makeRequest' manager <$> r

workerWrapper :: Traversable t => C.Manager -> TQueue (t Request) -> TQueue (t (Either String Response)) -> IO ()
workerWrapper manager inBox outBox = forever $ do
  -- TODO: reduce to a single atomically block
  log $ "workerWrapper: reading req from inbox"
  req <- atomically $ readTQueue inBox
  log $ "workerWrapper: read req from inbox & performing IO now"
  resp <- sequence $ makeRequest' manager <$> req
  log $ "workerWrapper: writing response to outBox"
  atomically $ writeTQueue outBox resp
  log $ "workerWrapper: response wrote to outBox"
  return ()



makeRequest' :: C.Manager -> Request -> IO (Either String Response)
makeRequest' manager req = do
  let req' = Request.internalRequest req
  log $ "makeRequest: Requesting: " <> (show $ Request.uri req)
  resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
      log $ "makeRequest: Downloaded: " <> (show $ Request.uri req)
      let orginhost = C.host req'
          finalhost = C.host $ C.hrFinalRequest hr
          res = C.hrFinalResponse hr
      when ((/=) orginhost finalhost) $ E.throw $
        C.InvalidUrlException
          (show (C.getUri (C.hrFinalRequest hr)))
          "The response host does not match that of the request's."
      bss <- C.brConsume $ C.responseBody res
      return res { C.responseBody = BSL8.fromChunks bss }
  log $ (if (isRight resp) then "makeRequest: Success " else "makeRequest: Error ") <> (show $ Request.uri req)
  case resp of
    Left e -> return $ Left $ show  (e :: C.HttpException)
    Right r -> return (Right $ Response.mkResponse (Request.uri req) req r)

runSpider :: (Functor f, Traversable f, Show (f Request), Show b,
  Show (f Response),
 (Show (f (Either String Response)))) =>
                          SpiderDefinition f b -> IO ()
runSpider spiderDef = do
  let startReq = Request.mkRequest <$> _startUrl spiderDef
      extract = _extract spiderDef
      transform = fromMaybe return $_transform spiderDef
      load = fromMaybe (const (return ())) $ _load spiderDef
  -- bail if there is nothing to do.
  when (F.any isNothing startReq) (return ())
  -- make downloader queue and populate it with the first item.
  dlQ <- newJobQueueIO
  atomically $ writeJobQueue dlQ (fromJust <$> startReq)
  -- use a set to record/filter seen requests so we don't dl something > 1
  let seen   = S.empty :: S.Set String
  -- Spin up the downloader worker threads
  workerInBox <- newTQueueIO   :: IO (TQueue (f Request))
  workerOutBox <- newTQueueIO  :: IO (TQueue (f (Either String Response)))
  manager <- C.newManager tlsManagerSettings -- {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  replicateM_ 5 . forkIO $ workerWrapper manager workerInBox workerOutBox
  threadDelay 20000
  -- and, 'Welcome to the Machines'
  runT_ $
    jobQueueProducer dlQ
    -- ~> autoM (\r -> do;putStrLn "Got a request fresh out of the dlQ:";return r)
    -- TODO: DOWNLOADER Start
    -- TODO: dl-middleware-before
    -- ~> regulated 0.05
    ~> construct (filterDuplicates dlQ seen)
    ~> autoM (\r -> do;putStrLn "After filterDuplicates";return r)
    ~> schedular workerInBox workerOutBox dlQ
    ~> autoM (\r -> do;putStrLn "After filterDuplicates";return r)
    -- ~> autoM (\r -> do;putStrLn "Just downloaded that request";return r)
    -- TODO: handles lefts with a taskCompleteJobQueue dlq
    ~> repeatedly (do
        log $ "LeftFilter: awaits"
        r <- await
        if  F.any isLeft r then
          liftIO $ do
            log $ "LeftFilter: Left Value Found:  " <> show r
            atomically $ taskCompleteJobQueue dlQ
            log $ "LeftFilter: taskCompleteJobQueue"
          else do
            log $ "LeftFilter: Value was Right"
            yield r
      )
    -- ~> filtered (F.any isRight)
    ~> mapping (\r -> (head . rights . flip(:)[]) <$> r)
    -- TODO: dl-middleware-after
    -- TODO: DOWNLOADER END.
    -- Extractor
    ~> extractor dlQ extract
    ~> autoM (mapM transform)
    ~> autoM (\r -> do;putStrLn "Ran Transform:";return r)
    ~> asParts
    ~> autoM load
  return ()
    where
      extractor dlQ f = repeatedly (do
          log $ "extractor: awaits"
          resp <- await
          log $ "extractor: retrieved data"
          let results = f resp
              reqs = filter resultIsRequest results
              items = filter resultIsItem results
          x <- liftIO $ atomically $ do
            let reqs' = mapMaybe resultGetRequest reqs
            mapM_ (writeJobQueue dlQ) reqs'
            taskCompleteJobQueue dlQ
            return reqs'
          log $ "extractor: wrote ( " <> show (length x) <> " ) requests to jobQueue."
          log $ "extractor: taskCompleteJobQueue"
          activeCount <- liftIO $ atomically $ jobQueueActiveCount dlQ
          log $ "extractor: jobQueueActiveCount: (" <> show activeCount <> ")"
          let items' = mapMaybe resultGetItem items
          log $ "extractor: yielding " <> show (length items') <> " items."
          yield items'
          )
      -- filterDuplicates :: JobQueue (f Request) -> S.Set String -> PlanT (k (t Request)) (t Request) m ()
      filterDuplicates dlQ' seen = do
        log $ "filterDuplicates: awaits"
        req <- await
        let req' = head $ F.toList req
            path = URI.uriPath $ Request.uri req'
            duplicate = S.member path seen
        log $ "filterDuplicates: retirived item: " <> path
        unless duplicate $ do
          let seen' = S.insert path seen
          log $ "filterDuplicates: item is unique. yielding: " <> path
          yield req
          log $ "filterDuplicates: item is unique. yielded: " <> path
          filterDuplicates dlQ' seen'
        when duplicate $ do
          log $ "filterDuplicates: item duplicate."
          liftIO $ atomically $ taskCompleteJobQueue dlQ'
          log $ "filterDuplicates: taskCompleteJobQueue."
          activeCount <- liftIO $ atomically $ jobQueueActiveCount dlQ'
          log $ "filterDuplicates: jobQueueActiveCount " <> show activeCount
          filterDuplicates dlQ' seen
      schedular ib ob dlQ = construct go
        where
          drainOutBound ob' cnt = do
            drained <- liftIO $ atomically $ isEmptyTQueue ob'
            when drained (log $ "drainOutBound drained!")
            unless drained (do
              r <- liftIO $ atomically $ readTQueue ob'
              let path = URI.uriPath $ Response.uri $ (head $ rights $ F.toList r)
              yield r
              log $ "schedular:drainOutBound: yielded: " <> path
              log $ "schedular:drainOutBound: call # " <> show cnt
              drainOutBound ob' (succ cnt)
              )

          go = do
            log $ "=schedular enter="
            jqDrained <- liftIO $ atomically $ isEmptyJobQueue dlQ
            log $ "schedular: jqDrained: " <> show jqDrained
            unless jqDrained  (do
              log $ "schedular: awaiting data"
              x <- await
              let path = URI.uriPath $ Request.uri (head $ F.toList x)
              log $ "schedular: data aquired writing to worker inbox: " <> path
              liftIO $ atomically $ writeTQueue ib x
              log $ "schedular: data wrote to worker inbox: " <> path
              )
            outBoundDrained <- liftIO $ atomically $ isEmptyTQueue ob
            when outBoundDrained (log $ "schedular: outBoundDrained")
            unless outBoundDrained (do
              log $ "schedular: outBound has data! Yielding now."
              drainOutBound ob (1::Int)
              log $ "schedular: Yielded data"
              )
            when outBoundDrained (liftIO $ threadDelay 100000)
            active <- liftIO $ atomically $ isActiveJobQueue dlQ
            activeCount <- liftIO $ atomically $ jobQueueActiveCount dlQ
            log $ "schedular: jobQueueActiveCount " <> show activeCount
            when (not active) (do
              log $ "schedular: STOPPING (JobQueue is inActive)."
              stop
              )
            log $ "=schedular exit="
            go
