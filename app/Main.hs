{-# LANGUAGE OverloadedStrings, NoImplicitPrelude, DeriveFunctor, DeriveTraversable, DeriveFoldable #-}
module Main where
import           Prelude                     (Eq, Foldable, Functor, IO,
                                              Integer, Ord, Show, String,
                                              Traversable, filter, map, null,
                                              print, return, show, succ,
                                              ($), (.), (<$>), (>=), (==))
-- import Debug.Trace
import           Control.Monad               (join)
import           Data.Function               ((&))
import qualified Data.ByteString.Lazy.Char8  as BSL
import           Data.Either                 (Either (..))
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (Maybe (..), catMaybes, mapMaybe)
import           Data.Semigroup              ((<>))
-- html handling
import           Network.URI                 as URI
-- import qualified Data.Text                  as T
-- import           Data.Text.Encoding.Error   (lenientDecode)
-- import           Data.Text.Lazy.Encoding    (decodeUtf8With)
import           Text.HTML.TagSoup           (parseTags)
import           Text.HTML.TagSoup.Selection as TS


-- Library in the works
import           Charlotte
import qualified Charlotte.Request           as Request
import qualified Charlotte.Response          as Response

{-
This program crawls a website and records 'internal' links on a page.
Pages can then be rank'd via the # of other pages linking to them 'PageRank'.
-}
type Depth = Integer
data PageType a = Page Depth a
  deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

type DataItem = Map.Map String String
type ParseResult = Result PageType DataItem

siteMapSpider :: SpiderDefinition PageType DataItem
siteMapSpider = SpiderDefinition {
    _name = "site-map-generator"
  , _startUrl = Page 0 "http://local.lasvegassun.com/"
  , _extract = parse
  , _transform = Just pipeline
  , _load = []
}

main :: IO ()
main = runSpider siteMapSpider

-- parse :: Process (PageType Response) ParseResult
parse :: PageType Response -> [ParseResult]
parse (Page n resp) = do
  let reqs = parseLinks resp
      nextDepth = succ n
      results = map (Request . Page nextDepth) reqs
      mkDI l = Map.empty & Map.insert "page" l :: DataItem
  if null results then
    [Item $ mkDI "nothing found!"]
    else
      if n >= 1
        then [Item (mkDI (show $ Response.uri $ resp) & Map.insert "max-depth" "true")]
        else
          results <> map (Item . mkDI . URI.uriPath . Request.uri) reqs

parseLinks :: Response -> [Request]
parseLinks resp = let
  Right sel = parseSelector "a"
  responseUri = Response.uri resp
  currentHost = URI.uriRegName <$> URI.uriAuthority responseUri
  r = (BSL.unpack $ Response.body resp) :: String
  tags = parseTags r
  tt = filter TS.isTagBranch $ TS.tagTree' tags
  links = mapMaybe (TS.findTagBranchAttr "href" . TS.content) $ join $ TS.select sel <$> tt
  relLinks = map (show . (`URI.relativeTo` responseUri)) $
    mapMaybe URI.parseRelativeReference $
    filter URI.isRelativeReference links
  absLinks = map show $
    filter (\l->(==currentHost) $ URI.uriRegName <$> URI.uriAuthority l) $
    mapMaybe URI.parseAbsoluteURI $
    filter URI.isAbsoluteURI links
  in catMaybes $ Request.mkRequest <$> (absLinks <> relLinks)

pipeline :: DataItem -> IO DataItem
pipeline x = do
  print x
  return x
