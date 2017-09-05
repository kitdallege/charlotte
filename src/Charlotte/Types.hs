module Charlotte.Types (
    Meta
  , Flag
) where
import           Data.Dynamic               (Dynamic)
import           Data.Map.Strict            (Map)

type Meta = Map String Dynamic
type Flag = String
