{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Charlotte.Response (
    Response
  , mkResponse
  , uri
  , request
  , meta
  , flags
  -- computed
  , statusCode
  , body
) where
import ClassyPrelude
-- import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Data.Map.Strict            as Map
import qualified Network.HTTP.Client        as C
import qualified Network.HTTP.Types         as NT
import           Network.URI                as URI

import           Charlotte.Request          (Request)
import           Charlotte.Types            (Flag, Meta)

data Response = Response {
    uri              :: URI.URI
  , request          :: Request -- Charlotte.Request ?
  , originalResponse :: C.Response LByteString
  , meta             :: Meta
  , flags            :: [Flag]
} deriving (Show)

mkResponse :: URI -> Request -> C.Response LByteString -> Response
mkResponse uri' req resp = Response {
    uri = uri'
  , request = req
  , originalResponse = resp
  , meta = Map.empty
  , flags = []
  }


-- Make accessors/lens which just proxy to the responseOriginal
statusCode     :: Response -> Int
statusCode = NT.statusCode . C.responseStatus . originalResponse
-- responseVersion    :: Response -> NT.HttpVersion
-- responseHeaders    :: Response -> NT.RequestHeaders
body       :: Response -> LByteString
body = C.responseBody . originalResponse
-- responseCookieJar  :: Response -> NT.CookieJar
