{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
module Charlotte.Lens
    (
    --   Types.SpiderDefinition
      name
    , startUrl
    , extract
    , transform
    , load
    --, Types.Settings
    , botName
    , concurrentRequests
    , userAgent
    --,Types.CharlotteRequest
    , uri
    , flags
    , internalRequest
    , meta
    -- , Types.CharlotteResponse
    , originalResponse
    , request
    )
    where
import qualified Charlotte.Types as Types
import Lens.Micro.Platform

makeLenses ''Types.SpiderDefinition
makeFields ''Types.Settings
makeFields ''Types.CharlotteRequest
makeFields ''Types.CharlotteResponse
