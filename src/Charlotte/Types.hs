{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Charlotte.Types (
        Meta
      , Flag
      , JobQueue(..)
      , CharlotteRequest(..)
      , CharlotteResponse(..)
      , SpiderDefinition(..)
      , Result(..)
      , mkRequest
      , mkResponse
      , responseBody
      , responseStatusCode
      , resultIsItem
      , resultIsRequest
      , resultGetRequest
      , resultGetItem
  -- , jobQueueProducer
  , newJobQueueIO
  , writeJobQueue
  , readJobQueue
  , isEmptyJobQueue
  , isActiveJobQueue
  , taskCompleteJobQueue
) where
import ClassyPrelude
import           Data.Dynamic               (Dynamic)
import qualified Network.HTTP.Client        as C
import qualified Network.HTTP.Types         as NT
import           Network.URI                as URI
import           Data.Typeable              (Typeable)

type Meta = Map Text Dynamic
type Flag = Text

data CharlotteRequest = CharlotteRequest
    { requestUri             :: URI.URI
    , requestInternalRequest :: C.Request
    , requestMeta            :: Meta
    , requestFlags           :: [Flag]
    } deriving (Show, Typeable)

mkRequest :: Text -> Maybe CharlotteRequest
mkRequest url = do
  let uri' = URI.parseURI (unpack url)
  case uri' of
    Nothing -> Nothing
    Just uri'' -> Just CharlotteRequest {
        requestUri = uri''
      , requestInternalRequest = (C.parseRequest_ (unpack url)) {C.responseTimeout = C.responseTimeoutMicro 60000000}
      , requestMeta = mapFromList []
      , requestFlags = []
      }

data CharlotteResponse = CharlotteResponse
    { responseUri              :: URI.URI
    , responseRequest          :: CharlotteRequest -- Charlotte.Request ?
    , responseOriginalResponse :: C.Response LByteString
    , responseMeta             :: Meta
    , responseFlags            :: [Flag]
    } deriving (Show)

mkResponse :: URI -> CharlotteRequest -> C.Response LByteString -> CharlotteResponse
mkResponse uri' req resp = CharlotteResponse {
  responseUri = uri'
, responseRequest = req
, responseOriginalResponse = resp
, responseMeta = mapFromList []
, responseFlags = []
}


-- Make accessors/lens which just proxy to the responseOriginal
responseStatusCode     :: CharlotteResponse -> Int
responseStatusCode = NT.statusCode . C.responseStatus . responseOriginalResponse
-- responseVersion    :: Response -> NT.HttpVersion
-- responseHeaders    :: Response -> NT.RequestHeaders
responseBody       :: CharlotteResponse -> LByteString
responseBody = C.responseBody . responseOriginalResponse
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
    _name      :: !Text
  , _startUrl  :: (a, Text)                         -- source
  , _extract   :: a -> CharlotteResponse -> [Result a b]     -- extract
  , _transform :: Maybe (b -> IO b)                 -- transform
  , _load      :: Maybe (b -> IO ())                -- load
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
