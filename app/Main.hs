{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Main where
import           Prelude                     (Eq, IO, Int, Integer, Ord, Show,
                                              String, filter, length, map,
                                              mapM_, print, return, round, show,
                                              succ, uncurry, ($), (.), (<),
                                              (<$>), (==))
-- import Debug.Trace
import           Control.Monad               (join)
import qualified Data.ByteString.Lazy.Char8  as BSL
import           Data.Either                 (Either (..))
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (Maybe (..), catMaybes, mapMaybe)
import           Data.Semigroup              ((<>))
import           Data.Time.Clock.POSIX       (POSIXTime, getPOSIXTime)
import           GHC.Generics                (Generic)
import           Data.Binary                 (Binary)
import           System.IO                   (BufferMode (..), Handle,
                                              IOMode (..), hSetBuffering,
                                              stdout, withFile)
-- html handling
import           Network.URI                 (URI (..))
import qualified Network.URI                 as URI
import           Text.HTML.TagSoup           (parseTags)
import           Text.HTML.TagSoup.Selection as TS
import           Text.HTML.TagSoup.Tree      (TagTree, renderTree)
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
data PageType = Page Depth Ref
  deriving (Show, Eq, Ord, Generic)

instance Binary PageType

data MetaTag = MetaTag {
    metaTagRepr  :: !String
  , metaTagAttrs :: !(Map.Map String String)
} deriving (Show, Generic)

data PageData = PageData {
    pagePath  :: !String
  , pageLinks :: ![String]
  , pageDepth :: !Int
  , pageRef   :: !String
  , pageMeta  :: ![MetaTag]
} deriving (Show, Generic)

instance ToJSON MetaTag
instance ToJSON PageData

type ParseResult = Result PageType PageData

siteMapSpider :: SpiderDefinition PageType PageData
siteMapSpider = SpiderDefinition {
    _name = "site-map-generator"
  , _startUrl = (Page 1 "START", "http://local.lasvegassun.com/")
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
maxDepth = 2

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  -- timestamp <- show . (round :: POSIXTime -> Integer) <$> getPOSIXTime :: IO String
  mainDistributed
  -- mainDb timestamp
  -- mainJson timestamp

mainDistributed :: IO ()
mainDistributed = runSpiderDistributed siteMapSpider

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

-- Currently:
--   parse :: PageType Response -> [ParseResult]
--   parse (Page depth ref resp) = let
-- thinking of:
--   parse :: PageType -> Response -> [ParseResult]
--   parse (Page depth ref) resp = ...
-- I'm liking this more. It leaves the user-defined-type as
-- a tag that can be as complex/simple as desired. We just carry it along
-- during the process. (atm: Were making the user-defined-type a container
-- and then shoving whatever were working on in it). This puts a lot of
-- burden on the user to derive a kitchen sink worth of classes:
-- eg: (Show, Eq, Ord, Functor, Foldable, Traversable)
-- I can always stick this into a tuple to carry it around and recover back out
-- what i need with code working on a tuple (which is a lot more well understood)
-- than some user-defined-derived type.
--
-- parse :: (PageType, Response) -> [ParseResult]
-- parse ((Page depth ref), resp) = ...
-- This tuple'd style was the one originally mentioned in the reddit post that
-- got me thinking about this crap again... :)

parse :: PageType -> Response -> [ParseResult]
parse (Page depth ref) resp = let
  nextDepth = succ depth
  tagTree = parseTagTree resp
  links = parseLinks tagTree
  linkPaths = map URI.uriPath links
  metaTags = parseMetaTags tagTree
  responsePath = URI.uriPath $ Response.uri resp
  reqs = catMaybes $ Request.mkRequest <$> map show links
  results = map (\r->Request (Page nextDepth responsePath, r)) reqs
  items = [Item $ PageData responsePath linkPaths depth ref metaTags]
  in if depth < maxDepth then results <> items else items

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
  getAttrs = Map.fromList . TS.tagBranchAttrs . TS.content
  getRepr = renderTree . return . TS.content
  toMetaTag t = MetaTag (getRepr t) (getAttrs t)
  in map toMetaTag metaTags

pipeline :: PageData -> IO PageData
pipeline x = do
  print x
  return x
----------------------------------
-- Load(ers) and suporting code.
----------------------------------
-- JsonLines
loadJsonLinesFile :: ToJSON a => Handle -> a -> IO ()
loadJsonLinesFile fh item = BSL.hPutStrLn fh (encode item)

-- SQL
loadSqliteDb :: Connection -> PageData -> IO ()
loadSqliteDb conn PageData{..} = do
  withTransaction conn $ do
    pid <- addPage pagePath
    print $ "pid: " <> show pid
    mapM_ (addPageLink pid pageDepth pageRef) pageLinks
    mapM_ (addPageMeta pid) pageMeta
  print $ "Inserted (" <> show (length pageLinks) <> ") page_links!"
  print $ "Inserted (" <> show (length pageMeta) <> ") page_meta!"
  where
    addPage page = do
      execute conn insertPageStmt (Only page) -- TODO: UPSERT
      -- for whatever reason lastInsertRowId was unreliable.
      pid <- query conn "SELECT id FROM pages WHERE page = (?)" (Only page) :: IO [Only Int]
      case pid of
        []    -> return (-1)
        [x]   -> return $ fromOnly x
        (x:_) -> return $ fromOnly x
    addPageLink pid depth ref link  = do
      lid <- addPage link
      rid <- addPage ref
      execute conn insertPageLinkStmt (pid, lid, depth, rid)
    addPageMeta pid pm = do
        print $ "addPageMeta: pid:" <> show pid
        execute conn insertPageMetaStmt (pid, metaTagRepr pm)
        pmid <- lastInsertRowId conn
        mapM_ (uncurry (addMetaAttr pmid)) $ Map.toList $ metaTagAttrs pm
    addMetaAttr mid k v = execute conn insertPageMetaAttrsStmt (mid, k, v)


createTableStmts, dropTableStmts :: [Query]
dropTableStmts = [
    "DROP TABLE IF EXISTS pages"
  , "DROP TABLE IF EXISTS page_links"
  , "DROP TABLE IF EXISTS page_meta"
  , "DROP TABLE IF EXISTS meta_attrs"
  ]
createTableStmts = [
    "CREATE TABLE IF NOT EXISTS pages (\
    \ id INTEGER PRIMARY KEY, \
    \ page TEXT NOT NULL UNIQUE\
    \)"
  , "CREATE TABLE IF NOT EXISTS page_links (\
    \ id INTEGER PRIMARY KEY, \
    \ page INTEGER NOT NULL, \
    \ link INTEGER NOT NULL, \
    \ depth INTEGER NOT NULL, \
    \ ref INTEGER NULL, \
    \ FOREIGN KEY (page) REFERENCES pages(id) \
    \ FOREIGN KEY (link) REFERENCES pages(id) \
    \ FOREIGN KEY (ref) REFERENCES pages(id))"
  , "CREATE TABLE IF NOT EXISTS page_meta (\
    \ id INTEGER PRIMARY KEY, \
    \ page INTEGER NOT NULL, \
    \ repr TEXT  NOT NULL, \
    \ FOREIGN KEY(page) REFERENCES pages(id))"
  , "CREATE TABLE IF NOT EXISTS meta_attrs (\
    \ id INTEGER PRIMARY KEY, \
    \ meta INTEGER, \
    \ name TEXT, \
    \ value TEXT,\
    \ FOREIGN KEY(meta) REFERENCES page_meta(id))"
  ]
insertPageStmt, insertPageLinkStmt, insertPageMetaStmt, insertPageMetaAttrsStmt :: Query
insertPageStmt = "INSERT OR IGNORE INTO pages (page) VALUES (?)"
insertPageLinkStmt = "INSERT INTO page_links (page, link, depth, ref) VALUES (?,?,?,?)"
insertPageMetaStmt = "INSERT INTO page_meta (page, repr) VALUES (?, ?)"
insertPageMetaAttrsStmt = "INSERT INTO meta_attrs (meta, name, value) VALUES (?,?,?)"
