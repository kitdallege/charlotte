{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Charlotte (
    SpiderDefinition(..)
  , Result(..)
  , Response
  , runSpider
) where
import           Prelude                    (Bool (..), Foldable, Functor, IO,
                                             Maybe (..), Show (..), String,
                                             Traversable, filter, flip, length,
                                             mapM_, not, putStrLn, return,
                                             sequence, ($), (.), (<$>))
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Semigroup             ((<>))
import qualified Network.HTTP.Client        as C
import           Network.HTTP.Client.TLS    (tlsManagerSettings)
-- import qualified Network.HTTP.Types         as CT
-- import           Data.Text.Encoding.Error (lenientDecode)
-- import           Data.Text.Lazy.Encoding  (decodeUtf8With)
-- import qualified Data.Text                as T
-- import           Text.Taggy.Lens          (allNamed, attr, html)

type Response = C.Response BSL.ByteString

makeRequest :: Traversable t =>
  C.Manager ->
  t C.Request ->
  IO (t Response)
makeRequest mgr pr = sequence $ flip C.httpLbs mgr <$> pr

data Result a b =
    Request (a C.Request)
  | Item  b

instance Show b => Show (Result a b) where
  show (Request _) = "Result Request"
  show (Item i)    = "Result " <> show i

resultIsItem,resultIsRequest :: Result a b -> Bool
resultIsItem (Item _) = True
resultIsItem _        = False
resultIsRequest = not . resultIsItem

resultGetRequest :: Result a b -> Maybe (a C.Request)
resultGetRequest (Request r) = Just r
resultGetRequest _           = Nothing

data SpiderDefinition a b = SpiderDefinition {
    _name     :: String
  , _startUrl :: a String                                 -- source
  , _parse    :: a Response -> [Result a b]               -- extract
  , _pipeline :: Maybe ([Result a b] -> IO [Result a b])  -- transform
  , _exporters :: [Maybe ([Result a b] -> IO ())]         -- load
}

runSpider :: (Functor a, Foldable a, Traversable a, Show b) =>
  SpiderDefinition a b ->
  IO ()
runSpider spiderDef = do
  manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  let startReq = C.parseRequest_ <$>  _startUrl spiderDef
  processReq spiderDef manager (Request startReq)
  return ()

processReq :: (Traversable t, Show b)=>
  SpiderDefinition t b ->
  C.Manager ->
  Result t b ->
  IO ()
processReq spiderDef manager req = do
  let req' = resultGetRequest req
  case req' of
    Just r -> do
      resp <- makeRequest manager r
      let pipeline' = _pipeline spiderDef
          parse' = _parse spiderDef
          results = parse' resp
          items = filter resultIsItem results
          reqs = filter resultIsRequest results
      putStrLn $ "# of items found: " <> show (length items)
      case pipeline' of
        Just p -> do
          _ <- p items
          return ()
        Nothing -> return ()
      putStrLn $ "# of request found: " <> show (length reqs)
      mapM_ (processReq spiderDef manager) reqs
    Nothing -> putStrLn "No more requests."
  return ()
