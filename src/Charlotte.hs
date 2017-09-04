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
import           Control.Monad              (when, unless)
import           Data.Either                (isRight, rights)
import           Data.Maybe (fromJust, isNothing, fromMaybe, mapMaybe)
--import qualified Data.ByteString.Char8      as BS8
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
jobQueueProducer q = construct $ go
  where
    go = do
      liftIO $ print ("in go"::String)
      drained <- liftIO $ atomically $ isEmptyJobQueue q
      liftIO $ print ("drained is " <> (show drained)::String)
      when drained stop
      r <- liftIO $ atomically $ readJobQueue q
      liftIO $ print ("read a result from queue"::String)
      yield r
      liftIO $ print ("yield'd a result from queue"::String)
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

--- Spider/Downloader
worker :: Traversable t => C.Manager -> t Request -> IO (t (Either String Response))
worker manager r = sequence $ makeRequest' manager <$> r

makeRequest' :: C.Manager -> Request -> IO (Either String Response)
makeRequest' manager req = do
  -- Request.internalRequest
  let req' = Request.internalRequest req
  resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
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
  manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  let startReq = Request.mkRequest <$> _startUrl spiderDef
      extract = _extract spiderDef
      transform = fromMaybe (return) $_transform spiderDef
  when (F.any isNothing startReq) (return ())
  dlQ <- newJobQueueIO
  atomically $ writeJobQueue dlQ (fromJust <$> startReq)
  runT_ $
    jobQueueProducer dlQ
    ~> autoM (\r -> do
      putStrLn "Got a request fresh out of the dlQ:"
      return r
      )
    -- TODO: DOWNLOADER Start
    -- TODO: dl-middleware-before
    -- ~> scatter (replicate 3 (autoM (worker manager)))
    ~> autoM (worker manager)
    -- left Error -> error_handlers
    -- right response -> extract
    ~> autoM (\r -> do
        putStrLn "Just downloade that request"
        -- print r
        return r
      )
    ~> filtered (F.any isRight)
    ~> mapping (\r -> (head . rights . flip(:)[]) <$> r)
    -- TODO: dl-middleware-after
    -- TODO: DOWNLOADER END.
    -- ~> mapping extract
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
    -- ~> autoM (\r -> do
    --     taskCompleteJobQueue dlQ
    --     return r
    --  )
    -- ~> asParts
    -- ~> construct (do
    --     r <- await
    --     when(resultIsItem r) (yield r)
    --     when(resultIsRequest r) (do
    --       liftIO $ print "Writing to queue"
    --       let req = resultGetRequest r
    --       case req of
    --         Just r' -> liftIO $ (atomically $ writeJobQueue dlQ r') >> print "wrote to Queue"
    --         Nothing -> return ())
    --     )
    -- ~> filtered resultIsRequest
    -- ~> auto (\(Request r)-> r)
    -- ~> autoM (writeToQ dlQ)
    ~> autoM print
    -- ~> autoM transform
    -- ~> autoM load
  return ()
  where
    handles p a  s = if p s then a s else s


-- processReq :: (Traversable t, Show b)=>
--   SpiderDefinition t b ->
--   C.Manager ->
--   Result t b ->
--   IO ()
-- processReq spiderDef manager req = do
--   let req' = resultGetRequest req
--   case req' of
--     Just r -> do
--       resp <- makeRequest manager r
--       let pipeline' = _transform spiderDef
--           parse' = _extract spiderDef
--           results = parse' resp
--           items = filter resultIsItem results
--           reqs = filter resultIsRequest results
--       putStrLn $ "# of items found: " <> show (length items)
--       case pipeline' of
--         Just p -> do
--           --_ <- p catMaybes $ (mapM resultGetitems items)
--           return ()
--         Nothing -> return ()
--       putStrLn $ "# of request found: " <> show (length reqs)
--       mapM_ (processReq spiderDef manager) reqs
--     Nothing -> putStrLn "No more requests."
--   return ()
