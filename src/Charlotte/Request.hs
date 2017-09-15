module Charlotte.Request (
    Request
  , mkRequest
  , internalRequest
  , uri

) where
import qualified Data.Map.Strict     as Map
import qualified Data.Typeable       as T (Typeable)
import qualified Network.HTTP.Client as C
import           Network.URI         as URI

import           Charlotte.Types     (Flag, Meta)

data Request = Request {
    uri             :: URI.URI
  , internalRequest :: C.Request
  , meta            :: Meta
  , flags           :: [Flag]
} deriving (Show, T.Typeable)

mkRequest :: String -> Maybe Request
mkRequest url = do
  let uri' = URI.parseURI url
  case uri' of
    Nothing -> Nothing
    Just uri'' -> Just Request {
        uri = uri''
      , internalRequest = (C.parseRequest_ url) {C.responseTimeout = C.responseTimeoutMicro 60000000}
      , meta = Map.empty
      , flags = []
      }
