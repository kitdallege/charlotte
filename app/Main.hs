{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import ClassyPrelude
import           Data.Aeson.Text
import           Data.Aeson.Types hiding (parse, Result)
import qualified Data.Char                  as Char
import Control.Concurrent.Async (waitBoth)
import Data.ByteString             (breakSubstring)
import           Network.URI                 (URI (..))
import qualified Network.URI                 as URI
import           Text.HTML.TagSoup           (parseTags)
-- import           Text.StringLike (StringLike)
-- import qualified Text.StringLike as TS
import           Text.HTML.TagSoup.Selection as TS
import           Text.HTML.TagSoup.Tree      (TagTree)
import Text.StringLike.Matchable (Matchable(..))
import qualified Data.Text as T

import           System.IO                   (BufferMode (..), hSetBuffering,
                                            stdout)
import GHC.Generics (Generic)
-- Library in the works
import Lens.Micro.Platform
import           Charlotte
-- import qualified Charlotte.Request           as Request
-- import qualified Charlotte.Response          as CResponse

linkSelector :: Selector
Right linkSelector = parseSelector "a"


checkNull :: (s -> Bool) -> (s -> s -> Bool) -> (s -> s -> Bool)
checkNull null' comp s1 s2 = not (null' s1) && comp s1 s2

-- newtype MatchableText = MatchableText {unMatchableText :: Text} deriving (Show)
-- instance StringLike  where
--     TODO: I'm pretty sure this unwrap/wrap is a Profunctor
--     figure out if I'm right. if so, badass.
--     uncons = second MatchableText <$> (uncons . unMatchableText)
--     uncons (MatchableText t) = (,) . fst <*> (MatchableText $ snd) <$> uncons t
--     toString MatchableText t) = MatchableText (unpack t)
--     fromChar = singleton . unMatchableText
--     strConcat = concat . unMatchableText
--     empty = MatchableText ""
--     strNull = null . unMatchableText
--     cons = cons . unMatchableText
--     append = append . unMatchableText

instance Matchable Text where
    matchesExactly = (==)
    matchesPrefixOf = checkNull null isPrefixOf
    matchesInfixOf  = checkNull null isInfixOf
    matchesSuffixOf = checkNull null isSuffixOf
    matchesWordOf s = any (`matchesExactly` s) . T.splitOn " \t\n\r"

data SearchPattern = SearchPattern
  { spPattern     :: Text
  , spInvertMatch :: Bool
  } deriving (Show, Generic)

instance ToJSON SearchPattern where
  toJSON = genericToJSON (mkOptions 2)

mkOptions :: Int -> Options
mkOptions n = defaultOptions {fieldLabelModifier = lowerOne . drop n}
  where
    lowerOne (x:xs) = Char.toLower x : xs
    lowerOne []     = ""

data PageType = ScrapedPage Int Text
    deriving (Show, Eq, Ord, Generic)

data Match = Match
  { matchPath    :: Text
  , matchPattern :: SearchPattern
  , matchDepth   :: Int
  , matchRef     :: Text
  , matchInfo    :: [MatchInfo]
  } deriving (Show, Generic)

instance ToJSON Match where
  toJSON = genericToJSON (mkOptions 5)

data MatchInfo = MatchInfo
  { matchInfoLine   :: Int
  , matchInfoColumn :: Int
  } deriving (Show, Generic)

instance ToJSON MatchInfo where
  toJSON = genericToJSON (mkOptions 9)


siteSearchSpider :: SpiderDefinition PageType Match
siteSearchSpider = let
  Just crawlHostURI = URI.parseURI "http://local.lasvegassun.com"
  in defaultSpider (ScrapedPage 1 "START")
            & name .~ "wfind-spider"
            & startUrl .~ (ScrapedPage 1 "START", "http://local.lasvegassun.com")
            & extract .~ parse 0 [] crawlHostURI
  -- in SpiderDefinition {}
  --  name = "wfind-spider"
  -- , _startUrl = (ScrapedPage 1 "START", "http://local.lasvegassun.com")
  -- , _extract = parse 0 [] crawlHostURI
  -- , _transform = Nothing
  -- , _load = Nothing
  -- }

main :: IO ()
main = do
    chan <- newTChanIO
    a1 <- async $ wfind "http://local.lasvegassun.com" 2 [SearchPattern "<h1" False] chan
    a2 <- async $ loop chan
    _ <- waitBoth a1 a2
    return ()
  where
    loop chan = do
        mtext <- atomically $ readTChan chan
        case mtext of
            Nothing -> return ()
            Just txt -> do
                print txt
                loop chan

wfind :: Text -> Int -> [SearchPattern] -> TChan (Maybe Text) -> IO ()
wfind uri' depth patterns chan = do
  hSetBuffering stdout LineBuffering
  let suri = unpack uri'
      Just crawlHostURI = URI.parseURI suri
      spider = siteSearchSpider
            & startUrl .~ (ScrapedPage 1 "START", uri')
            & extract .~ parse depth patterns crawlHostURI
            & load .~ Just (\x -> do
                  let payload = encodeToLazyText x :: LText
                  atomically $ writeTChan chan $ Just (toStrict payload)
                  return ()
                  )
  _ <- atomically $ writeTChan chan $ Just "Starting Search..."
  _ <- runSpider spider
  _ <- atomically $ writeTChan chan Nothing
  return ()

parse :: Int -> [SearchPattern] -> URI -> PageType -> CharlotteResponse -> [Result PageType Match]
parse maxDepth patterns crawlHostURI (ScrapedPage depth ref) resp = let
  nextDepth = succ depth
  tagTree = parseTagTree resp
  links = parseLinks crawlHostURI tagTree
  responsePath = resp ^. uri & URI.uriPath & pack
  reqs = catMaybes $ mkRequest <$> map (pack . show) links
  results = map (\r->Request (ScrapedPage nextDepth responsePath, r)) reqs
  items = map Item $ mapMaybe (performPatternMatch resp responsePath depth ref) patterns
  in if depth < maxDepth then results <> items else items

performPatternMatch :: CharlotteResponse -> Text -> Int -> Text -> SearchPattern -> Maybe Match
performPatternMatch resp curPath depth ref pat = do
  let body = responseBody resp
      pat' = spPattern pat
      pat'' = encodeUtf8 pat' :: ByteString
      body' = toStrict body
      hasMatch = pat'' `isInfixOf` body'
      invertMatch = spInvertMatch pat
  if hasMatch && not invertMatch
      then Just $ Match curPath pat depth ref (mkMatchInfo pat'' body')
      else if invertMatch && not hasMatch then
          Just $ Match curPath pat depth ref []
          else Nothing

mkMatchInfo :: ByteString -> ByteString -> [MatchInfo]
mkMatchInfo pat body = let
    patT = decodeUtf8 pat
    bodyT = decodeUtf8 body
    linesWithIndexes = [(i, encodeUtf8 p) | (p, i) <- zip (lines bodyT) [1..], patT `isInfixOf` p]
    colIndex xs = length . fst $ breakSubstring pat xs
    infoItems = [(i, colIndex txt) | (i, txt) <- linesWithIndexes]
  in [MatchInfo l c | (l, c) <- infoItems]

parseTagTree :: CharlotteResponse -> [TagTree Text]
parseTagTree resp = let
  r = decodeUtf8 $ toStrict $ responseBody resp :: Text
  tags = parseTags r
  in filter TS.isTagBranch $ TS.tagTree' tags

parseLinks :: URI -> [TagTree Text] -> [URI]
parseLinks crawlHostURI tt = let
  maybeHostName l = URI.uriRegName <$> URI.uriAuthority l
  setHostName l = l {
      URI.uriAuthority=URI.uriAuthority crawlHostURI
    , URI.uriScheme = URI.uriScheme crawlHostURI}
  getHref = (TS.findTagBranchAttr "href" . TS.content)
  links = mapMaybe getHref $ join $ TS.select linkSelector <$> tt
  relLinks = filter ((==) (maybeHostName crawlHostURI) . maybeHostName) $
      map setHostName $
      mapMaybe URI.parseRelativeReference $
      filter URI.isRelativeReference $
      map unpack links
  absLinks = filter ((==) (maybeHostName crawlHostURI) . maybeHostName) $
      mapMaybe URI.parseAbsoluteURI $
      filter URI.isAbsoluteURI $
      map unpack links
  in (absLinks <> relLinks)
