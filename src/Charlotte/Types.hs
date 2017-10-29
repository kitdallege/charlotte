{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
module Charlotte.Types (
        Meta
      , Flag
      , JobQueue(..)
      , CharlotteRequest(..)
      , CharlotteResponse(..)
      , SpiderDefinition(..)
      , Result(..)
      , SpinderEnv(..)
      , SpiderT(..)
      , defaultSpider
      , runSpiderT
      , runSpiderNoLogging
      , runSpiderStdoutLogging
      , mkRequest
      , mkResponse
      , responseBody
      , responseStatusCode
      , resultIsItem
      , resultIsRequest
      , resultGetRequest
      , resultGetItem
      , SettingPresidence(..)
      , Settings(..)
      -- , jobQueueProducer
      , newJobQueueIO
      , writeJobQueue
      , readJobQueue
      , isEmptyJobQueue
      , isActiveJobQueue
      , taskCompleteJobQueue
      ) where
import           ClassyPrelude
import           Control.Monad.Logger
import           Data.Dynamic         (Dynamic)
import           Data.Typeable        (Typeable)
import qualified Network.HTTP.Client  as C
import qualified Network.HTTP.Types   as NT
import           Network.URI          as URI

type Meta = Map Text Dynamic
type Flag = Text

data CharlotteRequest = CharlotteRequest
    { charlotteRequestUri             :: URI.URI
    , charlotteRequestInternalRequest :: C.Request
    , charlotteRequestMeta            :: Meta
    , charlotteRequestFlags           :: Vector Text
    } deriving (Show, Typeable)

mkRequest :: Text -> Maybe CharlotteRequest
mkRequest url = do
  let uri' = URI.parseURI (unpack url)
  case uri' of
    Nothing -> Nothing
    Just uri'' -> Just CharlotteRequest {
        charlotteRequestUri = uri''
      , charlotteRequestInternalRequest = (C.parseRequest_ (unpack url)) {C.responseTimeout = C.responseTimeoutMicro 60000000}
      , charlotteRequestMeta = mapFromList []
      , charlotteRequestFlags = mempty
      }

data CharlotteResponse = CharlotteResponse
    { charlotteResponseUri              :: URI.URI
    , charlotteResponseRequest          :: CharlotteRequest -- Charlotte.Request ?
    , charlotteResponseOriginalResponse :: C.Response LByteString
    , charlotteResponseMeta             :: Meta
    , charlotteResponseFlags            :: [Flag]
    } deriving (Show)

mkResponse :: URI -> CharlotteRequest -> C.Response LByteString -> CharlotteResponse
mkResponse uri' req resp = CharlotteResponse {
  charlotteResponseUri = uri'
, charlotteResponseRequest = req
, charlotteResponseOriginalResponse = resp
, charlotteResponseMeta = mapFromList []
, charlotteResponseFlags = []
}


-- Make accessors/lens which just proxy to the responseOriginal
responseStatusCode     :: CharlotteResponse -> Int
responseStatusCode = NT.statusCode . C.responseStatus . charlotteResponseOriginalResponse
-- responseVersion    :: Response -> NT.HttpVersion
-- responseHeaders    :: Response -> NT.RequestHeaders
responseBody       :: CharlotteResponse -> LByteString
responseBody = C.responseBody . charlotteResponseOriginalResponse
-- responseCookieJar  :: Response -> NT.CookieJar


data Result a b =
    Request (a, CharlotteRequest)
    | Item  b

instance (Show a, Show b) => Show (Result a b) where
  show (Request (_, r)) = "Result Request (" <> show r <> ")"
  show (Item i)         = "Result " <> show i

resultIsItem :: Result a b -> Bool
resultIsItem (Item _)    = True
resultIsItem (Request _) = False

resultIsRequest :: Result a b -> Bool
resultIsRequest = not . resultIsItem

resultGetRequest :: Result a b -> Maybe (a, CharlotteRequest)
resultGetRequest (Request r) = Just r
resultGetRequest _           = Nothing

resultGetItem  :: Result a b -> Maybe b
resultGetItem  (Item r) = Just r
resultGetItem _         = Nothing


data SpiderDefinition a b = SpiderDefinition {
    _name      :: Text
  , _startUrl  :: (a, Text)                         -- source
  , _extract   :: a -> CharlotteResponse -> [Result a b]     -- extract
  , _transform :: Maybe (b -> IO b)                 -- transform
  , _load      :: Maybe (b -> IO ())                -- load
}

defaultSpider :: a -> SpiderDefinition a b
defaultSpider a = SpiderDefinition {
    _name      = mempty
  , _startUrl  = (a, mempty)
  , _extract   =  \_->const []
  , _transform = Nothing
  , _load      = Nothing
}
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


data SettingPresidence  =
      SettingsDefault
    | SettingsCommand
    | SettingsProject
    | SettingsSpider
    | SettingsCmdline
    deriving (Show, Eq, Ord, Enum)

data Settings = Settings
    {
      settingsUserAgent :: !Text
    , settingsBotName :: !Text
    , settingsConcurrentRequests :: !Int
    } deriving (Show)

{-
  Engine
    single-instance which holds refs to all services
    logging downloader scheduler signals
  Crawler/CrawlProcess/CrawlRunner
    start Engine

  Settings

  At a high level I want to be able to handle two use-cases.
  1. Single Spider / pipeline / loader
   - It needs to be easy to wire up a spider for a signle use case (think @ stack script)
   - From ghci I need to be able to iteratively develope the parse/pipeline/loader methods
  2. Mutiple Spider project
   - The ability to handle configuration @ a project level with spider-level
     overrides.
   - Execute spiders in parallel so that you can control overall activity to a
     given host. (I might have a spider per reddit community but i only want
     to hit the parent domain @ a given rate.)

  for the single holeshot spider i want something like
  > runSpider defaultSpiderSettings spiderDef
    -- under the hood this is doing something similar to the code below,
    -- just wrapped up in a nice API so you don't have to think about it.
  For the multi-spider project it'd be somethign more like
  > settings <- loadSettings -- from file and/or env
  > engine <- newEngine settings
  > crawler <- mkCrawler engine
  > addSpider crawler spiderDef1
  > addSpider crawler spiderDef2
  > runCrawler engine crawler -- this blocks until all crawlers have finished.


TODO: Provide lens into all the data structures to help promote a terse/concise
syntax. ie: Most of the functionality of the system will be exposed through
nested structures which expose various settings as well as extension points.

defaults & fieldLens .~ val
         & fieldLens2 .~ val

-}

data SpinderEnv = SpinderEnv
    { spiderManager :: C.Manager
    -- , spiderInQueue     :: forall a. (Show a) => JobQueue (a, CharlotteRequest)
    -- , spiderOutQueue    :: forall b. (Show b) => JobQueue [b]
    , spiderSeen    :: TVar (Set ByteString)
    }

newtype SpiderT m a = SpiderT {unSpiderT :: ReaderT SpinderEnv m a}
    deriving (
          Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadReader SpinderEnv
        , MonadLogger)

runSpiderT :: C.Manager -> SpiderT IO b -> IO b
runSpiderT mgr action = do
    seen   <- newTVarIO mempty :: IO (TVar (Set ByteString))
    let env = SpinderEnv mgr seen
    runReaderT (unSpiderT action) env

runSpiderNoLogging :: C.Manager -> SpiderT (NoLoggingT IO) b -> IO b
runSpiderNoLogging mgr action = do
    seen   <- newTVarIO mempty :: IO (TVar (Set ByteString))
    let env = SpinderEnv mgr seen
    liftIO $ runNoLoggingT $ runReaderT (unSpiderT action) env

runSpiderStdoutLogging :: C.Manager -> SpiderT (LoggingT IO) b -> IO b
runSpiderStdoutLogging mgr action = do
    seen   <- newTVarIO mempty :: IO (TVar (Set ByteString))
    let env = SpinderEnv mgr seen
    liftIO $ runStdoutLoggingT $ runReaderT (unSpiderT action) env
