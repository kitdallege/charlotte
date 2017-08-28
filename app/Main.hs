{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
import           Prelude                    (Eq, Foldable, Functor, IO, Integer,
                                             Ord, Show, String, Traversable,
                                             map, mapM_, otherwise, print,
                                             return, succ, take, ($), (&&), (.),
                                             (/=), (<$>), (<=), (>=), (||))

import qualified Network.HTTP.Client        as C


import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (Maybe (..), catMaybes)
import           Data.Semigroup             ((<>))
-- html handling
import           Control.Lens               (only, (&), (^..))
import qualified Data.Text                  as T
import           Data.Text.Encoding.Error   (lenientDecode)
import           Data.Text.Lazy.Encoding    (decodeUtf8With)
import           Text.Taggy.Lens            (allNamed, attr, html)

-- Library in the works
import           Charlotte

type Depth = Integer
data PageType a =
    InitialIndex a
  | Page Depth a
  deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

type DataItem = Map.Map String String
type ParseResult = Result PageType DataItem

mySpider :: SpiderDefinition PageType DataItem
mySpider = SpiderDefinition {
    _name = "test spider"
  , _startUrl = InitialIndex "https://www.metatags.org/all_metatags"
  , _parse = parse
  , _pipeline = Just pipeline
  , _exporters = []
}

main :: IO ()
main = do
  let startUrl = "http://local.lasvegassun.com"
      maxDepth = 3
      numConcurrent = 5
      spider = mySpider {_startUrl = InitialIndex startUrl}
  runSpider spider

parse :: PageType Response -> [ParseResult]
parse (InitialIndex r) = do
  let reqs = parseLinks r
  take 1 $ map (Request . Page 1) reqs
parse (Page n r) = do
  let reqs = parseLinks r
      results = map (Request . Page (succ n)) reqs
      mkDI l = Map.insert "link" l Map.empty :: DataItem
  if n >= 2
    then []
    else
      take 1 results <> map (Item . mkDI . BS.unpack . C.path) reqs

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

pipeline :: [Result PageType DataItem] -> IO [Result PageType DataItem]
pipeline xs = do
  mapM_ print xs
  return xs
