{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import           Prelude                     (Eq, Foldable, Functor, IO, Int,
                                              Integer, Ord, Show, String,
                                              Traversable, filter, length, map,
                                              mapM_, print, return, round,
                                              show, succ, ($), (.), (<), (<$>),
                                              (==), uncurry)
-- import Debug.Trace
import           Control.Monad               (join)
import qualified Data.ByteString.Lazy.Char8  as BSL
import           Data.Either                 (Either (..))
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (Maybe (..), catMaybes, mapMaybe)
import           Data.Semigroup              ((<>))
import           Data.Time.Clock.POSIX       (getPOSIXTime, POSIXTime)
import           GHC.Generics                (Generic)
import           System.IO                   (BufferMode (..), Handle
                                              , IOMode (..) -- used with jsonlines
                                              , hSetBuffering
                                              , stdout
                                              , withFile -- used with jsonlines
                                              )
-- html handling
import           Network.URI                 (URI (..))
import qualified Network.URI                 as URI
import           Text.HTML.TagSoup           (parseTags)
import           Text.HTML.TagSoup.Tree      (TagTree)
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

type MetaTag = Map.Map String String
data PageData = PageData {
    pagePath  :: String
  , pageLinks :: [String]
  , pageDepth :: Int
  , pageRef   :: String
  , pageMeta  :: [MetaTag]
} deriving (Show, Generic)


createTableStmts, dropTableStmts :: [Query]
dropTableStmts = [
    "DROP TABLE IF EXISTS page_links"
  , "DROP TABLE IF EXISTS page_meta"
  ]
createTableStmts = [
    "CREATE TABLE IF NOT EXISTS page_links (\
    \id INTEGER PRIMARY KEY, page TEXT NOT NULL, link TEXT NOT NULL, \
    \depth INTEGER NOT NULL, ref TEXT NOT NULL)"
  , "CREATE TABLE IF NOT EXISTS page_meta (\
    \id INTEGER PRIMARY KEY, page TEXT NOT NULL, \
    \name TEXT NOT NULL, value TEXT NOT NULL)"
  ]
insertPageLinkStmt, insertPageMetaStmt :: Query
insertPageLinkStmt = "INSERT INTO page_links (page, link, depth, ref) VALUES (?,?,?,?)"
insertPageMetaStmt = "INSERT INTO page_meta (page, name, value) VALUES (?,?,?)"

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

linkSelector, metaSelector :: Selector
Right linkSelector = parseSelector "a"
Right metaSelector = parseSelector "meta"

crawlHost :: String
crawlHost = "local.lasvegassun.com"

crawlHostURI :: URI
Just crawlHostURI = URI.parseURI "http://local.lasvegassun.com"

maxDepth :: Int
maxDepth = 4

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  timestamp <- show . (round::POSIXTime -> Integer) <$> getPOSIXTime :: IO String
  mainDb timestamp
  --mainJson

mainJson :: String -> IO ()
mainJson filenamePart =
  withFile ("/tmp/charlotte-" <> filenamePart <>".jl") WriteMode $ \hdl -> do
    hSetBuffering hdl LineBuffering
    runSpider siteMapSpider {_load = Just (loadJsonLinesFile hdl)}

mainDb :: String -> IO ()
mainDb filenamePart =
  withConnection ("/tmp/charlotte-" <> filenamePart <>".db") $ \conn -> do
    mapM_ (execute_ conn) dropTableStmts
    mapM_ (execute_ conn) createTableStmts
    runSpider siteMapSpider {_load = Just (loadSqliteDb conn)}

parse :: PageType Response -> [ParseResult]
parse (Page depth ref resp) = do
  let nextDepth = succ depth
      tagTree = parseTagTree resp
      links = parseLinks tagTree
      linkPaths = map URI.uriPath links
      metaTags = parseMetaTags tagTree
      responsePath = URI.uriPath $ Response.uri resp
      reqs = catMaybes $ Request.mkRequest <$> map show links
      results = map (Request . Page nextDepth responsePath) reqs
      items = [Item $ PageData responsePath linkPaths depth ref metaTags]
  if depth < maxDepth then results <> items else items

parseTagTree :: Response -> [TagTree String]
parseTagTree resp = let
  r = (BSL.unpack $ Response.body resp) :: String
  tags = parseTags r
  in filter TS.isTagBranch $ TS.tagTree' tags

parseLinks :: [TagTree String] -> [URI]
parseLinks tt = let
  maybeHostName l = URI.uriRegName <$> URI.uriAuthority l
  setHostName l = l {
      URI.uriAuthority=URI.uriAuthority crawlHostURI
    , URI.uriScheme = URI.uriScheme crawlHostURI}
  getHref = (TS.findTagBranchAttr "href" . TS.content)
  links = mapMaybe getHref $ join $ TS.select linkSelector <$> tt
  relLinks = filter ((==) (maybeHostName crawlHostURI) . maybeHostName) $
    map setHostName $
    mapMaybe URI.parseRelativeReference $
    filter URI.isRelativeReference links
  absLinks = filter ((==) (maybeHostName crawlHostURI) . maybeHostName) $
    mapMaybe URI.parseAbsoluteURI $
    filter URI.isAbsoluteURI links
  in (absLinks <> relLinks)

parseMetaTags :: [TagTree String] -> [MetaTag]
parseMetaTags tt = let
  metaTags = join $ TS.select metaSelector <$> tt
  toMetaTag = (Map.fromList . TS.tagBranchAttrs . TS.content)
  in map toMetaTag metaTags

pipeline :: PageData -> IO PageData
pipeline x = do
  print x
  return x

loadJsonLinesFile :: ToJSON a => Handle -> a -> IO ()
loadJsonLinesFile fh item = BSL.hPutStrLn fh (encode item)

loadSqliteDb :: Connection -> PageData -> IO ()
loadSqliteDb conn PageData{..} = do
  withTransaction conn $ do
    mapM_ (addPage pagePath pageDepth pageRef) pageLinks
    -- page <-fk- page_meta -fk-> meta where: meta is m2m [meta-attributes]
    --mapM_ (uncurry (addMeta pagePath)) $ join $ Map.toList <$> pageMeta
  print $ "Inserted (" <> show (length pageLinks) <> ") page_links!"
  where
    addPage page depth ref link = execute conn insertPageLinkStmt (page, link, depth, ref)
    addMeta page name value = execute conn insertPageMetaStmt (page, name , value)
