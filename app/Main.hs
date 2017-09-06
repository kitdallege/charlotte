{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import           Prelude                     (Eq, Foldable, Functor, IO, Int,
                                              Ord, Show, String, Traversable,
                                              filter, length, map, mapM_, null,
                                              print, return, show, succ, ($),
                                              (.), (<), (<$>), (==))
-- import Debug.Trace
import           Control.Monad               (join)
import qualified Data.ByteString.Lazy.Char8  as BSL
import           Data.Either                 (Either (..))
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (Maybe (..), catMaybes, mapMaybe)
import           Data.Semigroup              ((<>))
import           GHC.Generics                (Generic)
import           System.IO                   (BufferMode (..), Handle,
                                              IOMode (..), hSetBuffering,
                                              stdout, withFile)
-- html handling
import           Network.URI                 (URI (..))
import qualified Network.URI                 as URI
import           Text.HTML.TagSoup           (parseTags)
import           Text.HTML.TagSoup.Selection as TS
-- Export as Json
import           Data.Aeson                  (ToJSON, encode)
import           Database.SQLite.Simple
-- Library in the works
import           Charlotte
import qualified Charlotte.Request           as Request
import qualified Charlotte.Response          as Response

{-
This program crawls a website and records 'internal' links on a page.
Pages can then be rank'd via the # of other pages linking to them 'PageRank'.
-}
type Depth = Int
type Ref = String
data PageType a = Page Depth Ref a
  deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

type DataItem = Map.Map String String
data PageData = PageData {
    pagePath  :: String
  , pageLinks :: [String]
  , pageDepth :: Int
  , pageRef   :: String
} deriving (Show, Generic)

instance ToJSON PageData

type ParseResult = Result PageType PageData

siteMapSpider :: SpiderDefinition PageType PageData
siteMapSpider = SpiderDefinition {
    _name = "site-map-generator"
  , _startUrl = Page 1 "START" "http://local.lasvegassun.com/"
  , _extract = parse
  , _transform = Nothing -- Just pipeline
  , _load = Nothing
}

crawlHost :: String
crawlHost = "local.lasvegassun.com"

maxDepth :: Int
maxDepth = 4

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  print $ "Running " <> _name siteMapSpider
  -- withFile "/tmp/charlotte.jl" WriteMode (\ hdl -> do
  --   hSetBuffering hdl LineBuffering
  --   runSpider siteMapSpider {_load = Just (loadJsonLinesFile hdl)}
  -- )
  withConnection "/tmp/charlotte.db" (\conn -> do
    execute_ conn "DROP TABLE IF EXISTS page_links"
    execute_ conn "CREATE TABLE IF NOT EXISTS page_links (id INTEGER PRIMARY KEY, page TEXT NOT NULL, link TEXT NOT NULL, depth INTEGER NOT NULL, ref TEXT NOT NULL)"
    runSpider siteMapSpider {_load = Just (loadSqliteDb conn)}
    )
  print $ "Finished Running " <> _name siteMapSpider

parse :: PageType Response -> [ParseResult]
parse (Page depth ref resp) = do
  let nextDepth = succ depth
      links = parseLinks resp
      linkPaths = map URI.uriPath links
      responsePath = URI.uriPath $ Response.uri resp
      reqs = catMaybes $ Request.mkRequest <$> map show links
      results = map (Request . Page nextDepth responsePath) reqs
      items = [Item $ PageData responsePath linkPaths depth ref]
  if null results then [] else if depth < maxDepth then results <> items else items

parseLinks :: Response -> [URI]
parseLinks resp = let
  Right sel = parseSelector "a"
  responseUri = Request.uri $ Response.request resp
  -- currentHost = URI.uriRegName <$> URI.uriAuthority responseUri
  r = (BSL.unpack $ Response.body resp) :: String
  tags = parseTags r
  tt = filter TS.isTagBranch $ TS.tagTree' tags
  links = mapMaybe (TS.findTagBranchAttr "href" . TS.content) $ join $ TS.select sel <$> tt
  relLinks = map (`URI.relativeTo` responseUri) $
    mapMaybe URI.parseRelativeReference $
    filter URI.isRelativeReference links
  absLinks = filter (\l->(==Just crawlHost) $ URI.uriRegName <$> URI.uriAuthority l) $
    mapMaybe URI.parseAbsoluteURI $
    filter URI.isAbsoluteURI links
  in (absLinks <> relLinks)

pipeline :: PageData -> IO PageData
pipeline x = do
  print x
  return x

loadJsonLinesFile :: ToJSON a => Handle -> a -> IO ()
loadJsonLinesFile fh item = BSL.hPutStrLn fh (encode item)

loadSqliteDb :: Connection -> PageData -> IO ()
loadSqliteDb conn item = do
  let page = pagePath item
      depth = pageDepth item
      links = pageLinks item
      ref = pageRef item
  withTransaction conn $ mapM_ (addPage page depth ref) links
  print $ "Inserted (" <> show (length links) <> ") page_links!"
  where
    addPage page depth ref link = (execute conn "INSERT INTO page_links (page, link, depth, ref) VALUES (?,?,?,?)" (page, link, depth, ref))
