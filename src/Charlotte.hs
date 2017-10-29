-- stylish-haskell wants FlexibleContexts but its not needed for ghc.
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK show-extensions #-}
{-|
Module      : Charlotte
Description : Short description
Copyright   : (c) Some Guy, 2013
                  Someone Else, 2014
License     : BSD3 (see the file LICENSE)
Maintainer  : Kit Dallege <kitdallege@gmail.com>
Stability   : experimental
Portability : POSIX

Here is a longer description of this module, containing some
commentary with @some markup@.
-}
module Charlotte (
      module Charlotte.Lens
    , SpiderDefinition(SpiderDefinition)
    , CharlotteResponse
    , responseBody
    , CharlotteRequest
    , mkRequest
    , Result(..)
    , runSpider
    , defaultSpider
    ) where
import ClassyPrelude
-- import           Prelude                    (Bool (..), Double, Either (..), IO,
--                                              Maybe (..), Show (..), String,
--                                              const, filter, fst, length, mapM_,
--                                              not, print, putStrLn, realToFrac,
--                                              return, snd, ($), (&&), (&&), (.),
--                                              (/), (/=), (<), (<$>), (<=), (>))
-- import           Debug.Trace
import           Control.Concurrent         (forkIO)
import           Control.Concurrent.STM (check)
import qualified Control.Exception          as E
import           Control.Monad              (forever, mapM, replicateM_, void,
                                             when, (>>=))
import           Control.Monad.IO.Class     (MonadIO, liftIO)
-- import qualified Data.ByteString            as BS
-- import qualified Data.ByteString.Lazy.Char8 as BSL8
import GHC.Show (Show(..))
import           Data.Either                (isRight)
-- import           Data.Foldable              as F
import           Data.Maybe                 (fromJust, fromMaybe, isNothing,
                                             mapMaybe)
import           Data.Semigroup             ((<>))
-- import qualified Data.Set                   as S
import           Data.Time                  (diffUTCTime, getZonedTime,
                                             zonedTimeToUTC)
import qualified Network.HTTP.Client        as C
import           Network.HTTP.Client.TLS    (tlsManagerSettings)
import           Network.HTTP.Types         as NT
import qualified Network.URI                as URI
import Lens.Micro.Platform
import           Charlotte.Types
import           Charlotte.Lens


------ new stuff -----------

log' :: (MonadIO m) => Text -> m ()
log' str = liftIO $ putStrLn str

pipeline :: JobQueue [b] -> (b -> IO b) -> (b -> IO ()) -> IO ()
pipeline inBox transformFn loadFn = forever loop
  where
    loop = do
      log' "== pipeline get items =="
      items <- atomically $ readJobQueue inBox
      log' "pipeline got items"
      items' <- mapM transformFn items
      log' "pipeline transformed items"
      E.catch (mapM_ loadFn items') (print :: E.SomeException -> IO())
      _ <- atomically $ taskCompleteJobQueue inBox
      log' "== pipeline loaded items =="

workerWrapper :: Show a =>
  C.Manager ->
  JobQueue (a, CharlotteRequest) ->
  JobQueue [b] ->
  (a -> CharlotteResponse -> [Result a b]) ->
  TVar (Set ByteString) ->
  IO c
workerWrapper manager inBox outBox extractFn seen = forever loop
  where
    loop = do
      log' "workerWrapper: reading req from inbox"
      req <- atomically $ readJobQueue inBox
      log' "workerWrapper: read req from inbox & performing IO now"
      resp <- makeRequest' manager seen (snd req)
      case resp of
        Left str -> do
          log' $ "workerWrapper: download error: " <> str
          atomically $ taskCompleteJobQueue inBox
        Right resp' -> do
          let results = extractFn (fst req) resp'
              reqs = mapMaybe resultGetRequest $ filter resultIsRequest results
              items = mapMaybe resultGetItem $ filter resultIsItem results
          log' "workerWrapper: writing response to outBox"
        --   log' $ "workerWrapper: (" <> (strConv $ show (length items)) <> ") items."
        --   log' $ "workerWrapper: (" <> (strConv $ show (length reqs) :: Text) <> ") requests."
          atomically $ do
            writeJobQueue outBox items
            mapM_ (writeJobQueue inBox) reqs
            taskCompleteJobQueue inBox
          log' "workerWrapper: response wrote to outBox"
      return ()

makeRequest' :: C.Manager -> TVar (Set ByteString) -> CharlotteRequest -> IO (Either Text CharlotteResponse)
makeRequest' manager seen req = do
  let req' = req ^. internalRequest
      uri' = fromString $ URI.uriPath $ view uri req
  seen' <- atomically $ readTVar seen
  let duplicate = member uri' seen'
  if not duplicate then do
    atomically $ writeTVar seen (insertSet uri' seen')
    log' $ pack $ "makeRequest: Requesting: " <> show (view uri req)
    resp <- E.try $ C.withResponseHistory req' manager $ \hr -> do
        let orginhost = C.host req'
            finalReq = C.hrFinalRequest hr
            finalhost = C.host finalReq
            numOfRedirects = length $ C.hrRedirects hr
            res = C.hrFinalResponse hr
        log' $ pack $ "makeRequest: Downloaded: " <> show (concat [if C.secure finalReq then "https://" else "http://", C.host finalReq, C.path finalReq])
        log' $ pack $ "makeRequest: Redirect Check: orginhost=" <> show orginhost <> " finalhost=" <> show finalhost <> " (" <> show numOfRedirects <> ") redirects."
        when ((/=) orginhost finalhost) $ E.throw $
          C.InvalidUrlException
            (show (C.getUri (C.hrFinalRequest hr)))
            "The response host does not match that of the request's."
        bss <- C.brConsume $ C.responseBody res
        return res { C.responseBody = fromChunks bss }
    log' $ pack $ (if isRight resp then "makeRequest: Success " else "makeRequest: Error ") <> show (view uri req)
    case resp of
      Left e -> return $ Left $ pack $ show  (e :: C.HttpException)
      Right r ->
        let code = NT.statusCode (C.responseStatus r) in
          if 200 <= code && code < 300 then
            return (Right $ mkResponse (view uri req) req r)
            else
              return $ Left $ pack ("StatusCodeException: code=" <> show code <> " returned.")
    else
      return $ Left ("Duplicate request"::Text)

runSpider :: (Show f, Show b) => SpiderDefinition f b -> IO ()
runSpider spiderDef = do
  startTime <- getZonedTime
  putStrLn $ pack $ "============ START " <> show startTime <> " ============"
  let
      startReq = spiderDef ^. startUrl & _2 %~ mkRequest
      extractFn = spiderDef ^. extract
      transformFn = fromMaybe return $ spiderDef ^. transform
      loadFn = fromMaybe (const (return ())) $ spiderDef ^. load
  -- bail if there is nothing to do.
  when (any isNothing startReq) (return ())
  let startReq' = fromJust <$> startReq
  -- use a set to record/filter seen requests so we don't dl something > 1
  -- TODO: explore bytestring-trie to reduce the overhead of storing
  -- large numbers of urls in memory.
  seen   <- newTVarIO mempty :: IO (TVar (Set ByteString))
  -- Spin up the downloader worker threads
  workerInBox <- newJobQueueIO -- :: IO (JobQueue (f Request))
  workerOutBox <- newJobQueueIO  -- :: IO (TQueue (f Result )))
  manager <- C.newManager tlsManagerSettings {
      C.managerResponseTimeout = C.responseTimeoutMicro 60000000
    , C.managerModifyRequest = \req->return $ req {
        C.requestHeaders = [("User-Agent", "Charlotte/v0.0.1 (https://github.com/kitdallege/charlotte)")]
    }
  }
  -- {C.managerResponseTimeout = C.responseTimeoutMicro 60000000}
  replicateM_ 3 . forkIO $ workerWrapper manager workerInBox workerOutBox extractFn seen
  -- Spin up Pipeline worker thread
  void (forkIO $ pipeline workerOutBox transformFn loadFn)
  -- populate Queue with the first item.
  threadDelay 20000
  atomically $ writeJobQueue workerInBox startReq'
  -- Wait until the workerInBox is empty
  atomically $ do
    active <- isActiveJobQueue workerInBox
    check (not active)
  log' "WorkerInBox not active."
  threadDelay 20000
  atomically $ do
    active <- isActiveJobQueue workerOutBox
    check (not active)
  log' "workerOutBox is empty."
  endTime <- getZonedTime
  threadDelay 20000 -- hope that the pipeline tasks finish up TODO: Real solution
  count <- atomically $ readTVar seen >>= \s->return $ olength s
  putStrLn $ pack $ "Number of Pages Processed: " <> show count
  let diff = diffUTCTime (zonedTimeToUTC endTime) (zonedTimeToUTC startTime)
      perSec = (if count > 0 then realToFrac count / realToFrac diff else 0.0) :: Double
  putStrLn $ pack $ "Runtime: " <> show diff
  when (count > 0) (putStrLn $ pack $ "Pages Per Second: " <> show perSec)
  putStrLn $ pack $ "============ END " <> show endTime <> " ============"
  return ()
