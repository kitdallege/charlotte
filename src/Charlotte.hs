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
                                             head,
                                             length, mapM_, not, putStrLn, foldMap, id,
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
import Network.URI as URI
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
  , _load      :: [[b] -> IO ()]                -- load
}

------ new stuff -----------

queueProducer :: TQueue a -> PlanT k a IO ()
queueProducer q = exhaust $ atomically $ tryReadTQueue q

writeToQ :: TQueue b -> b -> IO b
writeToQ queue n = do
  atomically $ writeTQueue queue n
  return n

type URL = T.Text
data DownloadTask = DownloadTask
  { taskUrl   :: !URL
  , taskDepth :: Int
  , taskRef   :: !URL
  } deriving (Show)

data JobQueue a = JobQueue {-# UNPACK #-} !(TQueue a)
                           {-# UNPACK #-} !(TVar Int)
  deriving Typeable


-- jobQueueProducer :: JobQueue a -> PlanT k a IO ()
jobQueueProducer :: JobQueue a -> SourceT IO a
jobQueueProducer q = construct go
  where
    go = do
      drained <- liftIO $ atomically $ isEmptyJobQueue q
      when drained stop
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
isEmptyJobQueue (JobQueue _ active) = do
  c <- readTVar active
  return (c==0)


mkWorker :: (Traversable t, Category k) => C.Manager -> MachineT IO (k (t Request)) (t (Either String Response))
mkWorker manager = autoM $ worker manager

workerWrapper :: Traversable t => C.Manager -> TQueue (t Request) -> TQueue (t (Either String Response)) -> IO ()
workerWrapper manager inBox outBox = forever $ do
  -- TODO: reduce to a single atomically block
  req <- atomically $ readTQueue inBox
  resp <- sequence $ makeRequest' manager <$> req
  atomically $ writeTQueue outBox resp
  return ()

worker :: Traversable t => C.Manager -> t Request -> IO (t (Either String Response))
worker manager r = sequence $ makeRequest' manager <$> r

makeRequest' :: C.Manager -> Request -> IO (Either String Response)
makeRequest' manager req = do
  threadDelay 200000
  let req' = Request.internalRequest req
  liftIO $ print ("making request"::String)
  resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
      liftIO $ print ("made request"::String)
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
    Right r -> return (Right $ Response.mkResponse (Request.uri req) req' r)

runSpider :: (Functor f, Traversable f, Show (f Request), Show b,
  Show (f Response),
 (Show (f (Either String Response)))) =>
                          SpiderDefinition f b -> IO ()
runSpider spiderDef = do
  let startReq = Request.mkRequest <$> _startUrl spiderDef
      extract = _extract spiderDef
      transform = fromMaybe return $_transform spiderDef
      -- load = _load spiderDef
  -- bail if there is nothing to do.
  when (F.any isNothing startReq) (return ())
  -- make downloader queue and populate it with the first item.
  dlQ <- newJobQueueIO
  atomically $ writeJobQueue dlQ (fromJust <$> startReq)
  -- Spin up the downloader worker threads
  workerInBox <- newTQueueIO   :: IO (TQueue (f Request))
  workerOutBox <- newTQueueIO  :: IO (TQueue (f (Either String Response)))
  manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  replicateM_ 2 . forkIO $ workerWrapper manager workerInBox workerOutBox
  -- and, 'Welcome to the Machines'
  runT_ $
    jobQueueProducer dlQ
    ~> autoM (\r -> do
      putStrLn "Got a request fresh out of the dlQ:"
      return r
      )
    -- TODO: DOWNLOADER Start
    -- TODO: dl-middleware-before
    -- ~> scatter [mWorker (worker manager)]
    -- ~> autoM (worker manager)
    -- ~> mkWorker manager
    ~> regulated 0.2
    ~> autoM (\r->do
        liftIO $ atomically $ writeTQueue workerInBox r
        liftIO $ atomically $ readTQueue workerOutBox
      )
    -- left Error -> error_handlers
    -- right response -> extract
    ~> autoM (\r -> do
        putStrLn "Just downloaded that request"
        -- print r
        return r
      )
    -- TODO: handles lefts with a taskCompleteJobQueue dlq
    ~> repeatedly (do
        r <- await
        if  F.any isLeft r then
          (liftIO $ do
             print r
             atomically $ taskCompleteJobQueue dlQ
            )
          else
            yield r
      )
    ~> filtered (F.any isRight)
    ~> mapping (\r -> (head . rights . flip(:)[]) <$> r)
    -- TODO: dl-middleware-after
    -- TODO: DOWNLOADER END.
    -- Extractor start
    ~> repeatedly (do
        resp <- await
        let results = extract resp
            reqs = filter resultIsRequest results
            items = filter resultIsItem results
        liftIO $ print $ "writing to q " <> show (length reqs) <> " requests."
        _ <- liftIO $ atomically $ do
          let reqs' = mapMaybe resultGetRequest reqs
          mapM_ (writeJobQueue dlQ) reqs'
        _ <- liftIO $ atomically $ taskCompleteJobQueue dlQ
        yield $ mapMaybe resultGetItem items
        )
    -- Extractor end
    ~> autoM (mapM transform)
    -- ~> autoM load
  return ()
