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
  -- , jobQueueProducer
  , newJobQueueIO
  , writeJobQueue
  , readJobQueue
  , isEmptyJobQueue
  , taskCompleteJobQueue
) where
import           Prelude                    (Bool (..), Either (..), Foldable,
                                             Functor, IO, Maybe (..), Show (..),
                                             String, Traversable, Int, Double, fmap, filter, flip,
                                             head, const, realToFrac, (/),
                                             length, mapM_, not, putStr, putStrLn, foldMap, id,
                                             print, replicate, return, seq, sequence, ($),
                                             succ, pred, (==), (>), (&&), (<$),
                                             ($!), (.), (/=), (<$>), (>>))

import Debug.Trace
import Data.Foldable as F
import Control.Applicative ((*>))
import           Control.Monad              (when, unless, mapM, forever, replicateM_, void, (>>=))
import           Data.Either                (isLeft, isRight, rights)
import           Data.Maybe (fromJust, isNothing, fromMaybe, mapMaybe)
import Control.Category (Category)
import Control.Concurrent (threadDelay, forkIO, MVar, newMVar, readMVar, putMVar, tryReadMVar, tryPutMVar)
import           Data.Time                  (diffUTCTime, getZonedTime,
                                             zonedTimeToUTC)
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
-- import           Data.Machine
-- import           Data.Machine.Concurrent    (scatter, (>~>))
import Control.Concurrent.Async (async, wait)
-- import           Data.Machine.Regulated     (regulated)
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
-- log _ = return ()

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

pipeline :: TQueue [b] -> (b -> IO b) -> (b -> IO ()) -> IO ()
pipeline inBox transform load = forever loop
  where
    loop = do
      log "== pipeline get items"
      items <- atomically $ readTQueue inBox
      log "pipeline got items"
      items' <- mapM transform items
      log "pipeline transformed items"
      mapM_ load items'
      log "== pipeline loaded items"

workerWrapper :: Traversable a =>
  C.Manager ->
  JobQueue (a Request) ->
  TQueue [b1] ->
  (a Response -> [Result a b1]) ->
  TVar (S.Set String) ->
  IO b
workerWrapper manager inBox outBox extract seen = forever loop
  where
    loop = do
      log "workerWrapper: reading req from inbox"
      req <- atomically $ readJobQueue inBox
      log "workerWrapper: read req from inbox & performing IO now"
      resp <- sequence $ makeRequest' manager seen <$> req
      let resp' = head $ F.toList resp
      case resp' of
        Left str -> do
          log $ "workerWrapper: download error: " <> str
          atomically $ taskCompleteJobQueue inBox
        Right resp'' -> do
          let resp''' = resp'' <$ resp
              results = extract resp'''
              reqs = mapMaybe resultGetRequest $ filter resultIsRequest results
              items = mapMaybe resultGetItem $ filter resultIsItem results
          log "workerWrapper: writing response to outBox"
          log $ "workerWrapper: (" <> show (length items) <> ") items."
          log $ "workerWrapper: (" <> show (length reqs) <> ") requests."
          atomically $ do
            writeTQueue outBox items
            mapM_ (writeJobQueue inBox) reqs
            taskCompleteJobQueue inBox
          log "workerWrapper: response wrote to outBox"
      return ()



makeRequest' :: C.Manager -> TVar (S.Set String) -> Request -> IO (Either String Response)
makeRequest' manager seen req = do
  let req' = Request.internalRequest req
      uri = URI.uriPath $ Request.uri req
  seen' <- atomically $ readTVar seen
  let duplicate = S.member uri seen'
  if not duplicate then do
    atomically $ writeTVar seen (S.insert uri seen')
    log $ "makeRequest: Requesting: " <> show (Request.uri req)
    resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
        log $ "makeRequest: Downloaded: " <> show (Request.uri req)
        let orginhost = C.host req'
            finalhost = C.host $ C.hrFinalRequest hr
            res = C.hrFinalResponse hr
        when ((/=) orginhost finalhost) $ E.throw $
          C.InvalidUrlException
            (show (C.getUri (C.hrFinalRequest hr)))
            "The response host does not match that of the request's."
        bss <- C.brConsume $ C.responseBody res
        return res { C.responseBody = BSL8.fromChunks bss }
    log $ (if isRight resp then "makeRequest: Success " else "makeRequest: Error ") <> show (Request.uri req)
    case resp of
      Left e -> return $ Left $ show  (e :: C.HttpException)
      Right r -> return (Right $ Response.mkResponse (Request.uri req) req r)
    else
      return $ Left ("Duplicate request"::String)
runSpider :: (Functor f, Traversable f, Show (f Request), Show b, Show (f Response)) =>
                           SpiderDefinition f b -> IO ()
runSpider spiderDef = do
  startTime <- getZonedTime
  putStrLn $ "============ START " <> show startTime <> " ============"
  let startReq = Request.mkRequest <$> _startUrl spiderDef
      extract = _extract spiderDef
      transform = fromMaybe return $_transform spiderDef
      load = fromMaybe (const (return ())) $ _load spiderDef

  -- bail if there is nothing to do.
  when (F.any isNothing startReq) (return ())
  let startReq' = fromJust <$> startReq
  -- use a set to record/filter seen requests so we don't dl something > 1
  seen   <- newTVarIO S.empty :: IO (TVar (S.Set String))
  -- Spin up the downloader worker threads
  workerInBox <- newJobQueueIO -- :: IO (JobQueue (f Request))
  workerOutBox <- newTQueueIO  -- :: IO (TQueue (f Result )))
  manager <- C.newManager tlsManagerSettings {
      C.managerResponseTimeout = C.responseTimeoutMicro 60000000
    , C.managerModifyRequest = \req->return $ req {
        C.requestHeaders = [("User-Agent", "Charlotte/v0.0.1 (https://github.com/kitdallege/charlotte)")]
    }
  }
  -- {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  replicateM_ 3 . forkIO $ workerWrapper manager workerInBox workerOutBox extract seen
  -- Spin up Pipeline worker thread
  void (forkIO $ pipeline workerOutBox transform load)
  -- populate Queue with the first item.
  threadDelay 20000
  atomically $ writeJobQueue workerInBox startReq'
  -- Wait until the workerInBox is empty
  atomically $ do
    active <- isActiveJobQueue workerInBox
    check (not active)
  log "WorkerInBox not active."
  atomically $ do
    drained <- isEmptyTQueue workerOutBox
    check drained
  log "workerOutBox is empty."
  endTime <- getZonedTime
  threadDelay 20000 -- hope that the pipeline tasks finish up TODO: Real solution
  count <- atomically $ readTVar seen >>= \s->return $ S.size s
  putStrLn $ "Number of Pages Processed: " <> show count
  let diff = diffUTCTime (zonedTimeToUTC endTime) (zonedTimeToUTC startTime)
      perSec = (if count > 0 then realToFrac count / realToFrac diff else 0.0) :: Double
  putStrLn $ "Runtime: " <> show diff
  when (count > 0) (putStrLn $ "Pages Per Second: " <> show perSec)
  putStrLn $ "============ END " <> show endTime <> " ============"
  return ()
