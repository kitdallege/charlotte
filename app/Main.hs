{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import           Prelude                    (Eq, Foldable, Functor, IO, Integer,
                                             Ord, Show, String, Traversable,
                                             map, mapM_, otherwise, print, null, length, filter, flip,
                                             return, succ, take, ($), (&&), (.), (<), show,
                                             (/=), (<$>), (<=), (>=), (||), (!!))
import Debug.Trace
import qualified Network.HTTP.Client        as C
import Control.Monad (when, join)
import Data.Function ((&),)
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (Maybe (..), catMaybes, mapMaybe)
import Data.Either (Either(..))
import           Data.Semigroup             ((<>))
-- html handling
import           Network.URI                as URI
-- import           Control.Lens               (only, (&), (^..))
import qualified Data.Text                  as T
-- import           Data.Text.Encoding.Error   (lenientDecode)
-- import           Data.Text.Lazy.Encoding    (decodeUtf8With)
-- import           Text.Taggy.Lens            (allNamed, attr, html)

import Text.HTML.TagSoup (parseTags)
import Text.HTML.TagSoup.Selection as TS


-- Library in the works
import           Charlotte
import qualified Charlotte.Response as Response
import qualified Charlotte.Request as Request

{-
This program crawls a website and records meta-tags on a given page
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
      results = map (Request . Page (succ n)) reqs
      mkDI l = Map.empty & Map.insert "page" l :: DataItem
  if null results then
    [Item $ mkDI "nothing found!"]
    else
      -- if n >= 2 then []
      --   else
      take 1 results <> map (Item . mkDI . URI.uriPath . Request.uri) reqs



parseLinks :: Response -> [Request]
parseLinks resp = let
  Right sel = parseSelector "a"
  r = (BSL.unpack $ Response.body resp) :: String
  tags = parseTags r
  tt = filter TS.isTagBranch $ TS.tagTree' tags
  links = mapMaybe (TS.findTagBranchAttr "href" . TS.content) $ join $ TS.select sel <$> tt
  relLinks = filter URI.isRelativeReference links
  relLinks' = mapMaybe URI.parseRelativeReference relLinks
  responseUri = (Response.uri resp)
  relLinks'' = map (`URI.relativeTo` responseUri) relLinks'
  relLinks''' = map show relLinks''
  -- relLinks' = map show relLinks
  in catMaybes $ Request.mkRequest <$> relLinks'''

{-
parseLinks :: C.Response BSL.ByteString -> [C.Request]
parseLinks r = let
  body = decodeUtf8With lenientDecode $ C.responseBody r
  links = body ^.. html . allNamed (only "a") . attr "href" & catMaybes
  links' = filterLinks (T.pack "http://local.lasvegassun.com") links
  links'' = map mkAbs links'
  in C.parseRequest_ . T.unpack <$> links''

mkAbs :: T.Text -> T.Text
mkAbs p
  | "http://local.lasvegassun.com" `T.isPrefixOf` p = p
  | "//" `T.isPrefixOf` p = "http:" <> p
  | otherwise = "http://local.lasvegassun.com" <> p


filterLinks :: T.Text -> [T.Text] -> [T.Text]
filterLinks host' lnks' = [l | l <- lnks', isAbsolute host' l || isProtoRelative host' l || isRelative l ]
  where
    isRelative l =  "/" `T.isPrefixOf` l && (T.length l  <= 1 || (/=) '/' (T.index l 1))
    isAbsolute h l = ("http://" <> h) `T.isPrefixOf` l
    isProtoRelative h l = "//" `T.isPrefixOf` l && ("//" <> h) `T.isPrefixOf` l

-}
pipeline :: [Result PageType DataItem] -> IO [Result PageType DataItem]
pipeline xs = do
  mapM_ print xs
  return xs
