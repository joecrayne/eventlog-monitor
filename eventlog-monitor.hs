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
import System.IO.Unsafe (unsafeInterleaveIO)
import Text.Printf

import BS

data EventsMonitor = EventsMonitor
    { emThreadLabels   :: Map.Map String ThreadId
    , emThreadCounts   :: OrdPSQ ThreadId TPrio ThreadCounts
    , emThreshold      :: TPrio
    , emMaxRunning     :: Int
    , emMinRunning     :: Int
    , emCurrentRunning :: Int
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
newEventsMonitor = EventsMonitor
    { emThreadLabels   = Map.empty
    , emThreadCounts   = OrdPSQ.empty
    , emThreshold      = tprioMax
    , emMaxRunning     = 0
    , emMinRunning     = 0
    , emCurrentRunning = 0
    }

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

data ThreadPriority prio = ThreadPriority
    { tpMaxPriority :: prio
    , tpPrio        :: ThreadCounts -> prio
    }

ratioPriority :: ThreadPriority (Ratio Word64)
ratioPriority = ThreadPriority
    { tpMaxPriority = maxBound % 1
    , tpPrio = \counts -> case tLabel counts of
        "" -> maxBound % 1
        _  -> (tot + 1 - tTicksRunning counts) % (tot + 1)
         where
            tot = tCurrentTime counts - tStartTime counts
    }

{-
type TPrio = Ratio Word64

tprioMax :: TPrio
tprioMax = maxBound % 1

tprio :: ThreadCounts -> TPrio
tprio counts = case tLabel counts of
    "" -> tprioMax
    _  -> (tot + 1 - tTicksRunning counts) % (tot + 1)
 where
    tot = tCurrentTime counts - tStartTime counts
-}

type TPrio = (Word64,Down Word64)

tprioMax :: TPrio
tprioMax = (maxBound,Down 0)

tprio :: ThreadCounts -> TPrio
tprio counts = ( if tIsRunning counts then 0 else maxBound - (tCurrentTime counts `div` (maxBound `div` 100))
               , Down $ tTicksRunning counts)


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
updateCounts :: TPrio
                -> Event
                -> Maybe (Maybe (TPrio, ThreadCounts) -> Maybe (TPrio, ThreadCounts), ThreadId)
updateCounts thrsh Event{ evTime, evSpec = RunThread    tid                } = Just (setRunning  evTime True , tid)
updateCounts thrsh Event{ evTime, evSpec = StopThread   tid ThreadFinished } = Just (setFinished evTime thrsh, tid)
updateCounts thrsh Event{ evTime, evSpec = StopThread   tid stopStat       } = Just (setRunning  evTime False, tid)
updateCounts thrsh Event{ evTime, evSpec = WakeupThread tid otherCap       } = Nothing -- Just (setRunning  evTime True , tid)
updateCounts thrsh Event{ evTime, evSpec = ThreadLabel  tid lbl            } = Just (setLabel lbl            , tid)
updateCounts thrsh Event{                                                  } = Nothing

isRunning :: Event -> Maybe Bool
isRunning Event{evSpec = WakeupThread _ _} = Nothing -- Just True
isRunning Event{evSpec = StopThread   _ _} = Just False
isRunning Event{evSpec = RunThread    _  } = Just True
isRunning Event{}                          = Nothing

update :: Event -> EventsMonitor -> (EventsMonitor,Bool)
update ev m
    | Just (inc,tid) <- updateCounts (emThreshold m) ev
    , let chk         = checkThreshold $ emThreshold m
          (b,counts') = OrdPSQ.alter (chk inc) tid $ emThreadCounts m
          m'          = m { emThreadCounts = counts' }
        = (m', b)
    | otherwise
        = (m, False)

updateRunningCount :: Event -> EventsMonitor -> EventsMonitor
updateRunningCount ev m
    | Just True  <- isRunning ev
                = m { emMaxRunning     = if max == cnt then cnt + 1 else max
                    , emCurrentRunning = cnt + 1 }
    | Just False <- isRunning ev
                = m { emMinRunning     = if min == cnt then cnt - 1 else min
                    , emCurrentRunning = cnt - 1 }
    | otherwise = m
 where
    min = emMinRunning m
    max = emMaxRunning m
    cnt = emCurrentRunning m

showCounts :: PrintfArg t => (t, b, ThreadCounts) -> String
showCounts (tid,p,counts) = unwords
    [ printf "%6d" tid
    , printf "%13d" (tTicksRunning counts)
    , printf "%13d" (tTicksWaiting counts)
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
    putStrLn $ homeCursorCode ++ "-------------" ++ show (emMinRunning m, emMaxRunning m, emCurrentRunning m)
    foldM (\_ t -> do putStrLn $ clearLineCode ++ showCounts t
                      let (_,thresh,_) = t
                      return thresh)
          tprioMax
          (take 30 $ listByPrio $ emThreadCounts m)

updateIO :: EventsMonitor -> Event -> IO EventsMonitor
updateIO m ev = do
    let (m',b) = update ev $ updateRunningCount ev m
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
    h <- openFile fname ReadMode
    -- hSetBuffering h NoBuffering
    bs <- hGetContentsN 512 h
    either (hPutStrLn stderr) reportEvents $ readEventLog bs
