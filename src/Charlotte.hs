{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Charlotte (
    SpiderDefinition(..)
  , Result(..)
  , Response
  , runSpider
) where
import           Prelude                    (Bool (..), Either (..), Foldable,
                                             Functor, IO, Maybe (..), Show (..),
                                             String, Traversable, fmap, filter, flip,
                                             length, mapM_, not, putStrLn,
                                             print, replicate, return, sequence, ($),
                                             ($!), (.), (/=), (<$>), (>>))

import           Control.Monad              (when)
import           Data.Either                (isRight, rights)
import           Data.Maybe (fromJust)
--import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as BSL8
import           Data.Semigroup             ((<>))
import qualified Network.HTTP.Client        as C
import           Network.HTTP.Client.TLS    (tlsManagerSettings)

import           Control.Concurrent.STM
import qualified Control.Exception          as E
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Data.Machine
import           Data.Machine.Concurrent    (scatter)
import           Data.Machine.Regulated     (regulated)
-- import qualified Network.HTTP.Types         as CT
-- import           Data.Text.Encoding.Error (lenientDecode)
-- import           Data.Text.Lazy.Encoding  (decodeUtf8With)
-- import qualified Data.Text                as T
-- import           Text.Taggy.Lens          (allNamed, attr, html)

type Response = C.Response BSL8.ByteString

-- makeRequest :: (Functor t, Foldable t, Traversable t) =>
--   C.Manager ->
--   t C.Request ->
--   IO (t Response)
makeRequest mgr pr = sequence $ flip C.httpLbs mgr <$> pr

data Result a b =
    Request (a C.Request)
  | Item  b

instance (Show (a C.Request), Show b) => Show (Result a b) where
  show (Request r) = "Result Request (" <> show r <> ")"
  show (Item i)    = "Result " <> show i

resultIsItem,resultIsRequest :: Result a b -> Bool
resultIsItem (Item _) = True
resultIsItem _        = False
resultIsRequest = not . resultIsItem

resultGetRequest :: Result a b -> Maybe (a C.Request)
resultGetRequest (Request r) = Just r
resultGetRequest _           = Nothing

resultGetItem  :: Result a b -> Maybe b
resultGetItem  (Item r) = Just r
resultGetItem _         = Nothing

data SpiderDefinition a b = SpiderDefinition {
    _name      :: String
  , _startUrl  :: a String                                   -- source
  , _extract   :: a Response -> [Result a b]               -- extract
  , _transform :: Maybe ([Result a b] -> IO [Result a b])   -- transform
  , _load      :: [[b] -> IO ()]                -- load
}

------ new stuff -----------

queueProducer :: TQueue a -> PlanT k a IO ()
queueProducer q = exhaust $ atomically $ tryReadTQueue q

writeToQ :: TQueue b -> b -> IO b
writeToQ queue n = do
  atomically $ writeTQueue queue n
  return n


-- worker manager r = makeRequest' <$> r
--   where
--     makeRequest' url = do
--       req <- C.parseUrlThrow url
--       let req' = req {C.responseTimeout = C.responseTimeoutMicro 60000000}
--       return $ C.withResponseHistory req' manager $ \hr -> do
--           let orginhost = C.host req
--               finalhost = C.host $ C.hrFinalRequest hr
--               res = C.hrFinalResponse hr
--           when ((/=) orginhost finalhost) $ E.throw $
--             C.InvalidUrlException
--               (show (C.getUri (C.hrFinalRequest hr)))
--               "The response host does not match that of the request's."
--           bss <- C.brConsume $ C.responseBody res
--           return res { C.responseBody = BSL8.fromChunks bss }

      -- case resp of
      --   Left e  -> "Left String" --Left $ show (e :: C.HttpException)
      --   Right r -> "Right String" --Right $ BSL8.unpack $ C.responseBody r

--M.filtered isLeft ~> M.mapping (\l->lefts [l]) ~> M.asParts
-- mkDownloader mgr = scatter [autoM (worker mgr), autoM (worker mgr)]


  -- manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
    -- ~> filtered isRight
    -- ~> mapping (\r->rights[r])
    -- ~> asParts


-- runSpider :: (Functor a, Foldable a, Traversable a, Show b, Show a) =>
--   SpiderDefinition a b ->
--   IO ()
runSpider :: (Functor f, Traversable f, Show (f C.Request), Show b,
  Show (f (C.Response BSL8.ByteString))) =>
                          SpiderDefinition f b -> IO ()
runSpider spiderDef = do
  manager <- C.newManager tlsManagerSettings {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  let startReq = C.parseRequest_ <$> _startUrl spiderDef
      extract = _extract spiderDef

  dlQ <- newTQueueIO
  atomically $ writeTQueue dlQ startReq

  runT_ $
    construct (queueProducer dlQ)
    ~> autoM (\r -> do
      putStrLn "Just down from the Q:"
      print r
      return r
      )
    ~> autoM (makeRequest manager)
    ~> auto extract
    ~> asParts
    ~> filtered resultIsRequest
    ~> auto (\(Request r)-> r)
    ~> autoM (writeToQ dlQ)
    ~> autoM print
    -- ~> autoM transform
    -- ~> autoM load
  return ()
  where
    handles p a  = \s -> if (p s) then (a s) else s
    worker manager r = makeRequest' manager <$> r
    makeRequest' manager url = do
      req <- C.parseUrlThrow url
      let req' = req {C.responseTimeout = C.responseTimeoutMicro 60000000}
      return $ C.withResponseHistory req' manager $ \hr -> do
          let orginhost = C.host req
              finalhost = C.host $ C.hrFinalRequest hr
              res = C.hrFinalResponse hr
          when ((/=) orginhost finalhost) $ E.throw $
            C.InvalidUrlException
              (show (C.getUri (C.hrFinalRequest hr)))
              "The response host does not match that of the request's."
          bss <- C.brConsume $ C.responseBody res
          return res { C.responseBody = BSL8.fromChunks bss }


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
      let pipeline' = _transform spiderDef
          parse' = _extract spiderDef
          results = parse' resp
          items = filter resultIsItem results
          reqs = filter resultIsRequest results
      putStrLn $ "# of items found: " <> show (length items)
      case pipeline' of
        Just p -> do
          --_ <- p catMaybes $ (mapM resultGetitems items)
          return ()
        Nothing -> return ()
      putStrLn $ "# of request found: " <> show (length reqs)
      mapM_ (processReq spiderDef manager) reqs
    Nothing -> putStrLn "No more requests."
  return ()
