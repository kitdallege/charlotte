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
                                             succ, pred, (==), (>),
                                             ($!), (.), (/=), (<$>), (>>))

import Debug.Trace
import Data.Foldable as F
import           Control.Monad              (when, unless, mapM, forever, replicateM_, void)
import           Data.Either                (isLeft, isRight, rights)
import           Data.Maybe (fromJust, isNothing, fromMaybe, mapMaybe)
import Control.Category (Category)
import Control.Concurrent (threadDelay, forkIO)
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


-- jobQueueProducer :: JobQueue a -> PlanT k a IO ()
jobQueueProducer :: JobQueue a -> SourceT IO a
jobQueueProducer q = construct go
  where
    go = do
      active <- liftIO $ atomically $ isActiveJobQueue q
      unless active stop
      r <- liftIO $ atomically $ readJobQueue q
      yield r
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
  req <- atomically $ readTQueue inBox
  -- liftIO $ print $ "read req from inbox & performing now"
  resp <- sequence $ makeRequest' manager <$> req
  -- liftIO $ print $ "writing response to outBox"
  atomically $ writeTQueue outBox resp
  return ()



makeRequest' :: C.Manager -> Request -> IO (Either String Response)
makeRequest' manager req = do
  let req' = Request.internalRequest req
  -- liftIO $ print $ "making request: " <> (show $ Request.uri req)
  resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
      liftIO $ print $ "Requested: " <> (show $ Request.uri req)
      let orginhost = C.host req'
          finalhost = C.host $ C.hrFinalRequest hr
          res = C.hrFinalResponse hr
      when ((/=) orginhost finalhost) $ E.throw $
        C.InvalidUrlException
          (show (C.getUri (C.hrFinalRequest hr)))
          "The response host does not match that of the request's."
      bss <- C.brConsume $ C.responseBody res
      return res { C.responseBody = BSL8.fromChunks bss }
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
  seen    <- newTVarIO (S.empty :: S.Set String)
  -- Spin up the downloader worker threads
  workerInBox <- newTQueueIO   :: IO (TQueue (f Request))
  workerOutBox <- newTQueueIO  :: IO (TQueue (f (Either String Response)))
  manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  replicateM_ 5 . forkIO $ workerWrapper manager workerInBox workerOutBox

  -- and, 'Welcome to the Machines'
  runT_ $
    jobQueueProducer dlQ
    -- ~> autoM (\r -> do;putStrLn "Got a request fresh out of the dlQ:";return r)
    -- TODO: DOWNLOADER Start
    -- TODO: dl-middleware-before
    ~> repeatedly (filterDuplicates seen)
    -- ~> regulated 0.05
    ~> schedular workerInBox workerOutBox dlQ
    -- ~> autoM (\r -> do;putStrLn "Just downloaded that request";return r)
    -- TODO: handles lefts with a taskCompleteJobQueue dlq
    ~> repeatedly (do
        r <- await
        if  F.any isLeft r then
          liftIO $ do
             print r
             atomically $ taskCompleteJobQueue dlQ
          else
            yield r
      )
    ~> filtered (F.any isRight)
    ~> mapping (\r -> (head . rights . flip(:)[]) <$> r)
    -- TODO: dl-middleware-after
    -- TODO: DOWNLOADER END.
    -- Extractor
    ~> extractor dlQ extract
    ~> autoM (mapM transform)
    ~> asParts
    ~> autoM load
  return ()
    where
      extractor dlQ f = repeatedly (do
          resp <- await
          let results = f resp
              reqs = filter resultIsRequest results
              items = filter resultIsItem results
          -- liftIO $ print $ "writing to q " <> show (length reqs) <> " requests."
          _ <- liftIO $ atomically $ do
            let reqs' = mapMaybe resultGetRequest reqs
            mapM_ (writeJobQueue dlQ) reqs'
          _ <- liftIO $ atomically $ taskCompleteJobQueue dlQ
          yield $ mapMaybe resultGetItem items
          )
      filterDuplicates seen = do
        liftIO $ threadDelay 10
        req <- await
        s <- liftIO $ atomically $ readTVar seen
        let req' = head $ F.toList req
            path = URI.uriPath $ Request.uri req'
            duplicate = S.member path s
        unless duplicate $ do
          let s' = S.insert path s
          liftIO $ atomically $ writeTVar seen s'
          yield req
      schedular ib ob dlQ = construct go
        where
          drainOutBound ob' cnt = do
            drained <- liftIO $ atomically $ isEmptyTQueue ob'
            -- when drained (do;liftIO $ print $ "drainOutBound drained!")
            unless drained (do
              r <- liftIO $ atomically $ readTQueue ob'
              yield r
              -- liftIO $ print $ "drainging out bound: " <> show cnt
              drainOutBound ob' (succ cnt)
              )

          go = do
            liftIO $ threadDelay 1
            jqDrained <- liftIO $ atomically $ isEmptyJobQueue dlQ
            -- when jqDrained (do;liftIO $ print "jqDrained")
            unless jqDrained  (do
              -- liftIO $ print $ "schedular awaits data"
              x <- await
              -- liftIO $ print $ "data aquired writing to worker inbox"
              liftIO $ atomically $ writeTQueue ib x
              -- liftIO $ print $ "data wrote to worker inbox"
              )
            outBoundDrained <- liftIO $ atomically $ isEmptyTQueue ob
            liftIO $ threadDelay 1
            -- when outBoundDrained (do;liftIO $ print "outBoundDrained")
            unless outBoundDrained (do
              -- liftIO $ print $ "schedular yields data"
              drainOutBound ob (1::Int)
              -- liftIO $ print $ "schedular yielded data"
              )
            -- liftIO $ putStr $ ".s."
            active <- liftIO $ atomically $ isActiveJobQueue dlQ
            -- activeCount <- liftIO $ atomically $ jobQueueActiveCount dlQ
            -- liftIO $ print $ "jobQueueActiveCount: " <> show activeCount
            when (not active) (do
              -- liftIO $ print $ "STOPPING SCHEDULAR (JobQueue is inActive)."
              stop
              )
            go
