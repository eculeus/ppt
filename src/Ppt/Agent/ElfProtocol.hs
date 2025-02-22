{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Ppt.Agent.ElfProtocol where
import Control.Concurrent
import Control.Exception (handle, displayException)
import Control.Exception.Base
import Data.Aeson
import Data.Bits
import Data.Char
import Data.Maybe
import Data.Word
import Foreign.C.Error
import Foreign.Ptr
import GHC.Exception
import Numeric
import Ppt.ElfProcess
import Ppt.Frame.Layout
import Ppt.Frame.Util
import System.Exit
import System.Process
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Elf as E
import qualified Data.HashMap.Strict as HM
import qualified Data.List as L
import qualified Foreign.C.String as FCS
import qualified Foreign.Marshal.Alloc as FMA
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as VM
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified System.Console.GetOpt as GO
import qualified System.Posix.Process as POS
import           Data.Monoid ((<>))

C.context (C.baseCtx <> C.vecCtx)

C.include "ppt-control.h"
C.include "<sys/ipc.h>"
C.include "<sys/shm.h>"
C.include "<string.h>"
C.include "<stdio.h>"
C.include "<inttypes.h>"
C.include "<linux/perf_event.h>"
C.include "<asm/unistd.h>"
C.include "<perfmon/pfmlib.h>"
C.include "<perfmon/pfmlib_perf_event.h>"

roundUp :: Int -> Int -> Int
roundUp blockSz elemSz =
  let min = blockSz `div` elemSz
      additional = if (blockSz `mod` elemSz) > 0
        then 1
        else 0
  in (min + additional) * elemSz

-- Attach to a running process.
-- Command line arguments:
--  ppt attach -p <pid> -v <version> <spec>
-- Note, -v isn't yet implemented.
--
-- attachSetup pid symbolsWithPrefix

check :: String -> Bool -> Maybe String
check _ True = Nothing
check desc False = Just desc

-- Lazy evaluates to first error (or to the end of list)
checkErrors :: [Maybe String] -> IO ()
checkErrors ((Just s):ss) = die s
checkErrors (Nothing:ss) = checkErrors ss
checkErrors [] = return ()

numElementsInBuffer = 128
hmem_pfx = "_ppt_hmem_"
stat_pfx = "_ppt_stat_"
json_pfx = "_ppt_json_"


-- Params: (1) verbosity level.  0 = quiet.
--         (1) address of first element in shared memory array
--         (2) element to start at
--         (3) starting sequence number
--         (3) Number of elements in that array
--         (4) Size (in 4-byte words) of that each element
--         (5) Destination Vector.  Mutable.  Must be at least as big as shared memory block.
-- Returns (number copied, last index consumed, last_seqno)
readBuffer :: Int -> Ptr Int -> Int -> Word32 -> Int -> Int -> VM.IOVector C.CUInt -> IO (Int, Int, Word32)
readBuffer verbosity src start seqno bufelems elem_sz_in_words destvector =
  do  args <- VM.new 2
      let c_elem_sz_in_words = fromIntegral elem_sz_in_words
          c_bufelems = fromIntegral bufelems
          c_start = fromIntegral start
          c_seqno = fromIntegral seqno
          c_src = castPtr src
          c_verb = fromIntegral verbosity
      cnt <- [C.block| int {
                   const int elem_sz = $(uint32_t c_elem_sz_in_words);
                   const int nr_elems = $(uint32_t c_bufelems);
                   const uint32_t* start = $(uint32_t* c_src);
                   const uint32_t *end = &start[elem_sz * nr_elems];
                   const uint32_t *cur = &start[elem_sz * $(uint32_t c_start)];
                   const uint32_t shm_sz = (end - start) / elem_sz;
                   const uint32_t start_seqno = $(uint32_t c_seqno);
                   const int verb = $(int c_verb);
                   uint32_t seq_floor;
                   uint32_t *dest = $vec-ptr:(unsigned int* destvector);
                   uint32_t last_cur_seqno = start_seqno, stride = 0;
                   if (verb > 0) {
                       printf("last_cur_seqno set to %u, first seqno is %u\n", last_cur_seqno, *cur);
                       printf("start address: 0x%8p, cursor (%4d) address: %8p\n",
                              start, $(uint32_t c_start), cur);
                       if (verb > 1) {
                           for (const uint32_t *s = start; s != end; s += elem_sz) {
                              if (s == cur)
                                 printf("[%5d]\t", *s);
                              else
                                 printf("%7d\t", *s);
                           }
                           printf("\n");
                       }
                   }
                   uint32_t count = 0;

                   if (nr_elems >= start_seqno) {
                     seq_floor = 1;
                   } else {
                     seq_floor = start_seqno - nr_elems;
                   }
                   while (*cur && count < nr_elems &&
                          (*cur > last_cur_seqno
                           || (*cur <= seq_floor)
                           || (count == 0 && *cur != last_cur_seqno))) {
                     last_cur_seqno = *cur;
                     stride++;
                     count++;
                     cur += elem_sz;
                     if (nr_elems >= start_seqno) {
                       seq_floor = 1;
                     } else {
                       seq_floor = start_seqno - nr_elems;
                     }
                     if (cur == end) {
                        memcpy(dest, cur - (stride * elem_sz), stride * elem_sz * sizeof(uint32_t));
                        if (verb > 0) {
                            printf("[mid] saved %u items\n", stride);
                        }
                        dest += stride * elem_sz;
                        cur = start;
                        stride = 0;
                     }
                   }
                   memcpy(dest, cur - (stride * elem_sz), stride * elem_sz * sizeof(uint32_t));
                   $vec-ptr:(uint32_t * args)[0] = last_cur_seqno;
                   $vec-ptr:(uint32_t * args)[1] = (cur - start) / elem_sz;
                   if (verb > 0) {
                       printf("[end] saved %u items\n", stride);
                       printf("[end] last_cur_seqno = %d.  cursor=%ld\n", last_cur_seqno, (cur - start) / elem_sz);
                   }
                   return count;
                   } |]
      last_seqno <- VM.read args 0
      end <- VM.read args 1
      return (fromIntegral cnt, fromIntegral end, fromIntegral last_seqno)

getBuffers :: Int -> E.Elf -> [E.ElfSymbolTableEntry]
getBuffers pid process = symbolsWithPrefix process hmem_pfx

listBuffers :: Int -> IO ([String])
listBuffers pid = do
  process <- loadProcess pid
  let pfx_syms = getBuffers pid process
      hmem_syms = map BSC.unpack $ mapMaybe (snd . E.steName) $ pfx_syms
      buffers = map (drop (L.length hmem_pfx)) hmem_syms
  return buffers

initCounters :: IO (Bool)
initCounters = do
  res <- [C.exp| int{ pfm_initialize() } |]
  return $ (fromIntegral ( [C.pure| int { $(int res) == PFM_SUCCESS }|])) /= 0


data CounterInfo = InvalidCounter
                 | ArchitecturalCounter
                 | SyntheticCounter -- ^By linux perf subsystem, not a CPU counter
                 | RawCounter
                 deriving (Eq, Show)

-- |Identify the PMU of the counter and return that (if there is one).
-- Loads the 'perf_event_attr' pointed to by 'p' with data pulled from
-- libpfm.
loadCounter :: String -> C.CUIntPtr -> Int -> IO (Bool)
loadCounter s p verbosity = do
  let verb = fromIntegral verbosity
  counterName <- FCS.newCString s
  res <- [C.block| int {
            struct perf_event_attr* pe = (struct perf_event_attr*)$(uintptr_t p);
            memset(pe, 0, sizeof(struct perf_event_attr));
            pfm_perf_encode_arg_t pfm_arg = { pe, NULL, sizeof(pfm_perf_encode_arg_t), 0, 0, 0 };
            int pfm_ret = pfm_get_os_event_encoding($(const char* counterName), PFM_PLM3, PFM_OS_PERF_EVENT_EXT,
                                                    &pfm_arg);
            if (pfm_ret != PFM_SUCCESS) {
                printf("Failed to get perf encoding for %s (pe=%p): %s\n", $(const char* counterName),
                       pe, pfm_strerror(pfm_ret));
                return -1;
            } else {
                printf("Loaded %s to %p\n", $(const char* counterName), pe);
            }
            pe->disabled = 0;
            pe->exclude_kernel = 1;
            pe->exclude_hv = 1;
            pe->sample_type = PERF_SAMPLE_READ;
            pe->read_format = 0; // PERF_FORMAT_GROUP;
            const char *petype;
            switch (pe->type) {
               case PERF_TYPE_HARDWARE: petype = "PERF_TYPE_HARDWARE"; break;
               case PERF_TYPE_SOFTWARE: petype = "PERF_TYPE_SOFTWARE"; break;
               case PERF_TYPE_TRACEPOINT: petype = "PERF_TYPE_TRACEPOINT"; break;
               case PERF_TYPE_HW_CACHE: petype = "PERF_TYPE_HW_CACHE"; break;
               case PERF_TYPE_RAW: petype = "PERF_TYPE_RAW"; break;
               case PERF_TYPE_BREAKPOINT: petype = "PERF_TYPE_BREAKPOINT"; break;
               default:
                  petype = "(unknown)";
            }
            printf("%s: libpfm uses type %s\n", $(const char* counterName), petype);
            return pe->type;
          } |]
  FMA.free counterName

  return $ res /= (-1)

-- |Returns a pmu ID nr and the name of each PMU.  Then we can start
-- scanning the pmu prefixes to figure out which events we want.
findAllPMUs :: IO ([(Int, String)])
findAllPMUs = do
  let findPMU i = do
        res <- [C.block| const char* {
                   pfm_pmu_info_t pinfo;
                   memset(&pinfo, 0, sizeof(pinfo));
                   pinfo.size = sizeof(pinfo);
                   int ret = pfm_get_pmu_info($(int i), &pinfo);
                   if (ret != PFM_SUCCESS || !pinfo.is_present)
                        return NULL;
                   return pinfo.name;
                 }|]
        if nullPtr == res
        then return Nothing
        else do str <- FCS.peekCString res
                return $ Just (fromIntegral i, str)
      maxPMU = fromIntegral $ [C.pure| int { PFM_PMU_MAX }|]
  allValues <- mapM findPMU [0..maxPMU]
  let rawList = catMaybes allValues
  -- filter out ix86Arch, it's too flaky to use reliably.  We'll keep
  -- ABI support in for when I can come back to research it better.
  return $ filter (\(_, n) -> n /= "ix86arch") rawList

-- |Returns whether y is in x.
strstr :: String -> String -> Bool
strstr y x = isJust $  (y `L.isPrefixOf`) `L.findIndex` (L.tails x)

findCounter :: String -> String -> IO (Bool)
findCounter pmu event = do
  let pmuPfx = pmu ++ "::"
      pmuLen = length pmuPfx
      eventPfx = take pmuLen event
      hasPrefix = strstr "::" event
  if hasPrefix &&  False == (strstr pmuPfx event)
  then return False
  else do
    counterName <- FCS.newCString (pmu ++ "::" ++ event)
    res <- [C.block| int { return pfm_find_event($(const char* counterName)); } |]
    putStrLn ("[findCounter " ++ pmu ++ " " ++ event ++"] looking for " ++ pmu ++ "::" ++ event ++ ": " ++ show res)
    return $ res >= 0

-- |As a cheapie, reverse the counter names on the way in and we'll
-- just use the length as an index var.
setCounters :: [String] -> C.CUIntPtr -> Int -> IO (Bool)
setCounters ns shmAddr verbosity = do -- setCounters' ns p 0
  -- NOTE: architectural counters seem to segfault pretty regularly.  So skip them.
  pmus <- findAllPMUs
  putStrLn $ concatMap show pmus
  let candidates = [ (pmu, ctr) | (_, pmu) <- pmus, ctr <- ns ]
  qualifiedCounterNamesM <- mapM (\(pmu, ctr) -> do
                                     found <- findCounter pmu ctr
                                     if found
                                       then return $ Just (pmu ++ "::" ++ ctr)
                                       else return Nothing) candidates
  let qualifiedCounterNames = catMaybes qualifiedCounterNamesM
  -- Keep the infrastructure to use the arch counters later.
  setCounters' (zip (repeat Nothing) qualifiedCounterNames) shmAddr 0 0
  where
    setCounters' :: [(Maybe Word32, String)] -> C.CUIntPtr -> Int -> Int -> IO (Bool)
    setCounters' [] _ _ _ = return True
    setCounters' ((Just n, nm):ns) p idx next_rcx = do
      let c_idx = fromIntegral idx
          c_n = fromIntegral n
      addr <- [C.block| uintptr_t {
                  struct ppt_control *ctrl = (struct ppt_control*)$(uintptr_t shmAddr);
                  ctrl->counterdata[$(int c_idx)].rcx = $(int c_n);
                  return (uintptr_t) &ctrl->counterdata[$(int c_idx)].event_attr;
              }|]
      res <- loadCounter nm addr verbosity
      if res
        then setCounters' ns shmAddr (idx+1) next_rcx --(next_rcx + 1)
        else return False
--      setCounters' ns p (idx + 1) next_rcx

    setCounters' ((Nothing, nm):ns) p idx next_rcx = do
      let c_idx = fromIntegral idx
          c_rcx = fromIntegral next_rcx
      addr <- [C.block| uintptr_t {
                  struct ppt_control *ctrl = (struct ppt_control*)$(uintptr_t shmAddr);
                  ctrl->counterdata[$(int c_idx)].rcx = $(int c_rcx);
                  return (uintptr_t) &ctrl->counterdata[$(int c_idx)].event_attr;
              }|]
      res <- loadCounter nm addr verbosity
      if res
        then setCounters' ns shmAddr (idx+1) (next_rcx + 1)
        else return False

attachAndRun :: Int -> String -> (Int -> IntPtr -> JsonRep -> Int -> [String] -> IO ()) -> Int ->  [String] -> IO ()
attachAndRun pid bufferName runFn verbosity cntrs = do
  let verbStrLn s = if verbosity > 0 then putStrLn s else return ()
      nrCntrs = fromIntegral $ length cntrs
  process <- loadProcess pid
  ldcntrs <- if length cntrs > 0
    then do putStrLn "Initializing libpfm"
            initCounters
    else return True
  let ctrlStructSz = [C.pure| int{ sizeof(struct ppt_control) +
                                   (sizeof(struct perf_counter_entry) * ($(int nrCntrs) -1))} |]
      statSyms = symbolsWithPrefix process (stat_pfx ++ bufferName)
      jsonSyms = symbolsWithPrefix process (json_pfx ++ bufferName)
      hmemSyms = symbolsWithPrefix process (hmem_pfx ++ bufferName)
      -- These aren't evaluated until after checkErrors validates the lists.
      statSym = head statSyms
      jsonSym = head jsonSyms
      hmem_sym = head hmemSyms
  checkErrors [
    check "Initializing libpfm" ldcntrs,
    check (concat ["Could not find ", stat_pfx, bufferName]) $ (length statSyms == 1),
    check (concat ["Could not find ", json_pfx, bufferName]) $ (length jsonSyms == 1),
    check (concat ["Could not find ", hmem_pfx, bufferName]) $ (length hmemSyms == 1)
    ]
  ourPid <- POS.getProcessID
  moldPid <- swapIntegerInProcess pid statSym 0 (fromIntegral ourPid)
  mabiStr <- stringInProcess pid jsonSym
  let (Just oldPid) = moldPid
      (Just abiStr) = mabiStr
      Just (json, totalBufferSize) = do
        abiStr <- mabiStr
        json <- (decode $ BSL.fromStrict abiStr) :: Maybe JsonRep
        elemSize <- frameSize json
        return (json, fromIntegral $ (roundUp (fromIntegral ctrlStructSz) elemSize) + (elemSize * numElementsInBuffer))
  checkErrors [
    check ("Failed to read symbol in pid " ++ show pid) $ isJust moldPid,
    check ("Process appears busy with ppt pid " ++ show oldPid) $ oldPid /= 0,
    check ("Failed to read buffer metadata from " ++ show pid) $ isJust mabiStr
    ]
  -- Ok, we have the lock in this process nad the JSON read.  Now create the shared mem block
  -- and try to attach it.
  shmId <- throwErrnoIfMinus1 "Failed to allocate shared memory" (
    [C.exp| int {shmget(IPC_PRIVATE, $(size_t totalBufferSize), IPC_CREAT | IPC_EXCL | 0600)} |])
  verbStrLn $ "Got shared memory handle " ++ show shmId
  verbStrLn $ "  Element size is " ++ show (frameSize json)
  if verbosity > 2
    then showLayoutData json
    else return ()
  let cleanup pid shmId = do
          moldHandle <- swapIntegerInProcess pid hmem_sym (fromIntegral shmId) 0
          checkErrors [
            check "Failed to clear shared memory handle" (isJust moldHandle),
            let (Just oldHandle) = moldHandle
            in check ("Got back old memory handle " ++ show oldHandle) $ (fromIntegral oldHandle) == 0
            ]
          throwErrnoIfMinus1_ ("Failed to delete shared memory segment " ++ show shmId) (
              [C.exp| int {shmctl( $(int shmId), IPC_RMID, NULL)} |])
          swapIntegerInProcess pid statSym (fromIntegral ourPid) 0
          return ()

      reportError :: String -> IO (C.CInt) -> IO ()
      reportError err fn = do
         res <- fn
         if (fromIntegral res) == -1
         then do --errno <- getErrno
                 putStrLn $ err -- ++ ": " ++ show errno
         else return ()
      errHandler :: IOError -> IO ()
      errHandler ex = do putStrLn ("ERROR: " ++ displayException ex)
                         cleanup pid shmId
      ctrlcHandler :: AsyncException -> IO ()
      ctrlcHandler UserInterrupt = cleanup pid shmId
      ctrlcHandler ex = do putStrLn ("ERROR: " ++ displayException ex)
                           cleanup pid shmId
  handle ctrlcHandler $ handle errHandler $ do
    shmAddr <- throwErrnoIfMinus1 "Failed to attach shared memory block" (
      [C.exp| uintptr_t {(uintptr_t) shmat($(int shmId), NULL, 0)} |])
    let cntrLen = fromIntegral $ length cntrs
    [C.block| void {
      struct ppt_control *pc = (struct ppt_control*) $(uintptr_t shmAddr);
      pc->control_blk_sz = $(int ctrlStructSz);
      pc->data_block_hmem = 0;
      pc->nr_perf_ctrs = $(uint32_t cntrLen);
      pc->client_flags = 0;
      printf("set %p -> nr_perf_ctrs to %d\n", pc, $(uint32_t cntrLen));
      } |]

    gotCounters <- setCounters cntrs shmAddr verbosity
    checkErrors [ check "Failed to setup performance counters" gotCounters ]
    moldHandle <- swapIntegerInProcess pid hmem_sym 0 (fromIntegral shmId)
    checkErrors [
      check "Failed to set shared memory handle" (isJust moldHandle),
      let (Just oldHandle) = moldHandle
      in check ("Got back old memory handle " ++ show oldHandle) $ (fromIntegral oldHandle) == shmId
      ]
    verbStrLn "Shared memory attached."
    runFn verbosity (fromIntegral shmAddr) json numElementsInBuffer cntrs
    cleanup pid shmId
  verbStrLn "Done."

