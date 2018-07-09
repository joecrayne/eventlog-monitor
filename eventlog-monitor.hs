{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}

import Control.Monad
import Data.Bool
import qualified Data.ByteString.Lazy as L
import Data.List
import qualified Data.Map.Strict      as Map
import Data.Ord
import qualified Data.OrdPSQ          as OrdPSQ
         ;import Data.OrdPSQ          (OrdPSQ)
import Data.Ratio
import Data.Word
import GHC.RTS.Events                 as Events
import GHC.RTS.Events.Incremental
import System.Environment
import System.IO
import Text.Printf

data EventsMonitor = EventsMonitor
    { emThreadLabels :: Map.Map String ThreadId
    , emThreadCounts :: OrdPSQ ThreadId TPrio ThreadCounts
    , emThreshold    :: TPrio
    }
 deriving Show

data ThreadCounts = ThreadCounts
    { tStartTime    :: Events.Timestamp
    , tCurrentTime  :: Events.Timestamp -- ^ Last-update time for this record.
    , tTicksRunning :: Word64 -- ^ Cumulative running-time between tStartTime and tCurrentTime.
    , tTicksWaiting :: Word64 -- ^ Cumulative waiting-time between tStartTime and tCurrentTime.
    , tIsRunning    :: Bool -- ^ True if was running as of tCurrentTime.
    , tLabel        :: String
    }
 deriving (Eq,Ord,Show)

newEventsMonitor :: EventsMonitor
newEventsMonitor = EventsMonitor Map.empty OrdPSQ.empty tprioMax

initCounts :: Events.Timestamp -> (TPrio, ThreadCounts)
initCounts tm = (tprio t0, t0)
 where t0 = ThreadCounts
        { tStartTime    = tm
        , tCurrentTime  = tm
        , tTicksRunning = 0
        , tTicksWaiting = 0
        , tIsRunning    = False
        , tLabel        = ""
        }

type TPrio = Ratio Word64

tprioMax :: TPrio
tprioMax = maxBound % 1

tprio :: ThreadCounts -> TPrio
tprio counts = case tLabel counts of
    "" -> tprioMax
    _  -> (tot + 1 - tTicksRunning counts) % (tot + 1)
 where
    tot = tCurrentTime counts - tStartTime counts

setRunning :: Events.Timestamp -> Bool -> Maybe (TPrio, ThreadCounts) -> Maybe (TPrio, ThreadCounts)
setRunning tm isRunning Nothing           = setRunning tm isRunning (Just $ initCounts tm)
setRunning tm isRunning (Just (p,counts)) = Just (tprio counts',counts')
 where
    delta = tm - tCurrentTime counts

    counts' = counts
        { tCurrentTime  = tm
        , tTicksRunning = bool id (+ delta) (tIsRunning counts) $ tTicksRunning counts
        , tTicksWaiting = bool (+ delta) id (tIsRunning counts) $ tTicksWaiting counts
        , tIsRunning    = isRunning
        }

-- ThreadFinished
setFinished :: Timestamp
              -> TPrio
              -> Maybe (TPrio, ThreadCounts)
              -> Maybe (TPrio, ThreadCounts)
setFinished tm thresh what
    | p' <= thresh = Just (p', counts')
    | otherwise    = Nothing
 where
    Just (p',counts') = setRunning tm False what

setLabel :: String -> Maybe (TPrio, ThreadCounts) -> Maybe (TPrio, ThreadCounts)
setLabel lbl (Just (p,counts)) = Just (p,counts { tLabel = lbl })
setLabel lbl Nothing           = Nothing -- Can't label a thread that doesn't exist.


checkThreshold :: Ord p => p -> (a -> Maybe (p, b)) -> a -> (Bool, Maybe (p, b))
checkThreshold threshold updater = chk . updater
 where
    chk v@(Just (p,_)) = (p <= threshold, v)
    chk v              = (False         , v)


listByPrio :: (Ord k, Ord p) => OrdPSQ k p v -> [(k,p,v)]
listByPrio q = case OrdPSQ.minView q of
    Just (k,p,v,q') -> (k,p,v) : listByPrio q'
    Nothing         -> []

-- For reference, here are some other Events that are not handled here but mention
-- a ThreadId:
--
--  CreateThread
--  ThreadRunnable
--  MigrateThread
--  CreateSparkThread
--  AssignThreadToProcess
--  MerReleaseThread
--
-- updateCounts :: Event -> EventsMonitor -> (EventsMonitor, Maybe ThreadCounts)
updateCounts :: TPrio
                -> Event
                -> Maybe (Maybe (TPrio, ThreadCounts) -> Maybe (TPrio, ThreadCounts), ThreadId)
updateCounts thrsh Event{ evTime, evSpec = RunThread    tid                } = Just (setRunning  evTime True , tid)
updateCounts thrsh Event{ evTime, evSpec = StopThread   tid ThreadFinished } = Just (setFinished evTime thrsh, tid)
updateCounts thrsh Event{ evTime, evSpec = StopThread   tid stopStat       } = Just (setRunning  evTime False, tid)
updateCounts thrsh Event{ evTime, evSpec = WakeupThread tid otherCap       } = Just (setRunning  evTime True , tid)
updateCounts thrsh Event{ evTime, evSpec = ThreadLabel  tid lbl            } = Just (setLabel lbl            , tid)
updateCounts thrsh Event{                                                  } = Nothing

update :: Event -> EventsMonitor -> (EventsMonitor,Bool)
update ev m
    | Just (inc,tid) <- updateCounts (emThreshold m) ev
    , let chk         = checkThreshold $ emThreshold m
          (b,counts') = OrdPSQ.alter (chk inc) tid $ emThreadCounts m
          m'          = m { emThreadCounts = counts' }
        = (m', b)
    | otherwise
        = (m, False)

showCounts :: PrintfArg t => (t, b, ThreadCounts) -> String
showCounts (tid,p,counts) = unwords
    [ printf "%6d" tid
    , printf "%12d" (tTicksRunning counts)
    , printf "%12d" (tTicksWaiting counts)
    , tLabel counts
    ]

-- | 'csi' @parameters controlFunction@, where @parameters@ is a list of 'Int',
-- returns the control sequence comprising the control function CONTROL
-- SEQUENCE INTRODUCER (CSI) followed by the parameter(s) (separated by \';\')
-- and ending with the @controlFunction@ character(s) that identifies the
-- control function.
csi :: [Int]  -- ^ List of parameters for the control sequence
    -> String -- ^ Character(s) that identify the control function
    -> String
csi args code = "\ESC[" ++ concat (intersperse ";" (map show args)) ++ code

clearScreenCode, homeCursorCode, clearLineCode :: String
clearScreenCode = csi [2] "J"
homeCursorCode  = csi [] "H"
clearLineCode   = csi [2] "K"

displayReport :: EventsMonitor -> IO TPrio
displayReport m = do
    putStrLn $ homeCursorCode ++ "-------------"
    foldM (\_ t -> do putStrLn $ clearLineCode ++ showCounts t
                      let (_,thresh,_) = t
                      return thresh)
          tprioMax
          (take 30 $ listByPrio $ emThreadCounts m)

updateIO :: EventsMonitor -> Event -> IO EventsMonitor
updateIO m ev = do
    let (m',b) = update ev m
    reverse (show ev) `seq` return () -- Force all event data.
    if b then do
        thresh <- displayReport m'
        return m' { emThreshold = thresh }
    else
        return m'

reportEvents :: (EventLog,Maybe String) -> IO ()
reportEvents (elog,merr) = do
    let Data evs = dat elog
    putStrLn clearScreenCode
    foldM_ updateIO newEventsMonitor evs
    mapM_ (hPutStrLn stderr) merr

main :: IO ()
main = do
    args <- getArgs
    let [fname] = args
    bs <- L.readFile fname
    either (hPutStrLn stderr) reportEvents $ readEventLog bs
