import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as BC
import System.Environment
import System.Exit
import Data.Binary.Get
import Data.Word
import Text.Printf
import Data.Bits
import Data.List
import Data.Char
import Data.Functor
import Data.Maybe
import Control.Monad
import System.Directory
import Numeric (showHex)

--import Codec.Container.Ogg.Page

mainTableOffset :: Get Word32
mainTableOffset = do
    getWord32le

mainTable :: Word32 -> Get [Word32]
mainTable offset = do
    skip (fromIntegral offset)
    -- It seems that the third entry points to the end of the table
    until <- lookAhead $ do
        skip 4
        skip 4
        getWord32le
    let n_entries = fromIntegral ((until - offset) `div` 4)
    replicateM n_entries getWord32le

getJumpTableOffsets :: B.ByteString -> Word32 -> [Word32]
getJumpTableOffsets bytes offset = flip runGet bytes $ do
    skip (fromIntegral offset)
    n <- getWord16le
    first <- lookAhead getWord32le
    replicateM (fromIntegral n) getWord32le

getJumpTableLineLength :: B.ByteString -> Word32 -> Word32
getJumpTableLineLength bytes offset =
    let (_,_,to) = runGetState (skip (fromIntegral offset) >> lineParser) bytes 0
    in fromIntegral to - offset

getJumpTable :: B.ByteString -> Word32 -> [B.ByteString]
getJumpTable bytes offset = flip map offs $ \from ->
    let to = from + getJumpTableLineLength bytes from
    in runGet (extract from (fromIntegral to - from)) bytes
  where
    offs = getJumpTableOffsets bytes offset

hyp2 :: B.ByteString -> Bool
hyp2 b =
    if b `B.index` 0 == 0x01
    then B.pack [0x01,0x00,0x00,0x00,0x00,0xF9,0xFF,0x01] `B.isPrefixOf` b
    else True

hyps = [ (hyp2, "01 fixed prefix")
       ]

data Command
    = A Word16
    | B Word8 Word8
    | C
    | D Word8
    | E
    | F Word16
    deriving Eq

data Line = Line LineHeader [Command] [Word16]

data LineHeader
    = MultiLine Bool Word16 Word8 Word8
    | SingeLine Bool Word16 

ppLine :: Line -> String
ppLine (Line h cs xs) = ppLineHeader h ++ ": " ++ spaces (map ppCommand cs) ++ " [" ++ commas (map show xs) ++ "]"

ppLineHeader :: LineHeader -> String
ppLineHeader (MultiLine v m g a) = printf "ML%s(%d,%d,%d)" (quote v) m g a
ppLineHeader (SingeLine v m)     = printf "SL%s(%d)" (quote v) m

quote True = "'"
quote False= ""

ppCommand :: Command -> String
ppCommand (A n) = printf "A(%d)" n
ppCommand (B a b) = printf "B(%d-%d)" a b
ppCommand (C) = printf "C"
ppCommand (D b) = printf "D(%d)" b
ppCommand E = printf "E"
ppCommand (F n) = printf "F(%d)" n

spaces = intercalate " "
commas = intercalate ","

parseLine :: B.ByteString -> Line
parseLine = runGet lineParser

lineParser :: Get Line
lineParser = begin
 where
    cmds =
        [ (B.pack [0xE8,0xFF,0x01], format2 A)
        , (B.pack [0x00,0xFC,0x01], formatB)
        , (B.pack [0xFF,0xFA,0x01,0xFF,0xFF], format2 (const C))
        , (B.pack [0x00,0xFD,0x01], formatD)
        , (B.pack [0xF0,0xFF,0x01,0x01,0x00], skip 5 >> return E)
        , (B.pack [0xF9,0xFF,0x01], formatF)
        ]
    -- Find the occurrence of a header
    begin = do
        (h,cs) <- getHeader
        -- Audio links
        n <- getWord16le
        xs <- replicateM (fromIntegral n) getWord16le
        return $ Line h cs xs

    expectWord8 n = do
        n' <- getWord8
        when (n /= n') $ do
            b <- bytesRead
            fail $ printf "At position %0X, expected %d/%02X, got %d/%02X" (b-1) n n n' n'

    getHeader = do
        t <- getWord8
        case t of
            1 -> do -- Single line
                expectWord8 0
                expectWord8 0
                vb <- getWord8
                v <- case vb of 0 -> return False
                                0x1E -> return True
                                _ -> fail "Unexpected byte for single line header"
                expectWord8 0
                expectWord8 0xF9
                expectWord8 0xFF
                expectWord8 0x01
                m <- getWord16le
                b <- getWord8
                expectWord8 0
                when (b /= 0) $ do
                    getWord8
                    getWord8
                    return ()
                -- Commands are separated by 0x0000
                cmds <- padded (fromIntegral b) getCmd
                return (SingeLine v m, cmds)
            2 -> do -- Multi-Line
                expectWord8 0
                expectWord8 0
                expectWord8 0
                expectWord8 0
                expectWord8 0xF9
                expectWord8 0xFF
                expectWord8 0x01
                m <- getWord16le
                expectWord8 0
                g <- getWord8
                expectWord8 0
                x <- getWord8
                v <- case x of 0xF9 -> return False
                               0xFB -> return True
                               _ -> fail $ printf "Unexpected byte %0X for multi line header" x
                expectWord8 0xFF
                expectWord8 0x01
                a <- getWord8
                expectWord8 0
                b <- getWord8
                expectWord8 0
                g2 <- getWord8
                unless (g == g2) $ fail "Values for g are not equal in multi line header"
                expectWord8 0
                cmds <- padded (fromIntegral b) getCmd
                return (MultiLine v m g a, cmds)
            n -> fail $ "Unknown line tag" ++ show n

    padded 0 a = return []
    padded 1 a = (:[]) <$> a
    padded n a = do
        x <- a
        0 <- getWord16le
        (x:) <$> padded (n-1) a


    getCmd = do
        r <- getRemainingLazyByteString
        case find (\(h,f) -> h `B.isPrefixOf` r) cmds of
          Just (h,f) -> f
          Nothing -> fail $ "unexpected command: " ++ prettyHex r

    formatF = do
        skip 3
        n <- getWord16le
        return $ F n

    format2 con = do
        skip 3
        m <- getWord16le
        return $ con m

    formatB = do
        skip 3
        a <- getWord8
        b <- getWord8
        return $ B a b

    formatD = do
        skip 3
        b <- getWord8
        0 <- getWord8
        return $ D b


checkLine :: Int -> Line -> [String]
checkLine n_audio l@(Line _ _ xs)
    | any (>= fromIntegral n_audio) xs
    = return $ "Invalid audio index in line " ++ ppLine l
checkLine n_audio _ = []

audioTableOffset :: Get Word32
audioTableOffset = do
    skip 4
    getWord32le

audioTable :: Word32 -> Get [(Word32, Word32)]
audioTable offset = do
    skip (fromIntegral offset)
    until <- lookAhead getWord32le
    let n_entries = fromIntegral ((until - offset) `div` 8)
    replicateM n_entries $ do
        ptr <- getWord32le
        len <- getWord32le
        return (ptr, len)

checkAT :: B.ByteString -> Int -> (Word32, Word32) -> IO Bool
checkAT bytes n (off, len) =
    if fromIntegral off > B.length bytes
    then do
        printf "    Entry %d: Offset %d > File size %d\n"
            n off (B.length bytes)
        return False
    else if fromIntegral (off + len) > B.length bytes
         then do
            printf "    Entry %d: Offset %d + Lengths %d > File size %d\n"
                n off len (B.length bytes)
            return False
         else return True

extract :: Word32 -> Word32 -> Get (B.ByteString)
extract off len = do
    skip (fromIntegral off)
    getLazyByteString (fromIntegral len)

getXor :: Word32 -> Get (Word8)
getXor off = do
    skip (fromIntegral off)
    present <- getLazyByteString 4
    -- Brute force, but that's ok here
    return $ head $
        [ n
        | n <- [0..0xFF]
        , decypher n present `elem` map fst fileMagics
        ]

fileMagics :: [(B.ByteString, String)]
fileMagics =
    [ (BC.pack "RIFF", "wav")
    , (BC.pack "OggS", "ogg")]

decypher :: Word8 -> B.ByteString -> B.ByteString
decypher x = B.map go
    where go 0 = 0
          go 255 = 255
          go n | n == x    = n
               | n == xor x 255 = n
               | otherwise = xor x n

{-
checkOgg :: B.ByteString -> IO ()
checkOgg ogg = do
    let (tracks, pages, rest) = pageScan ogg
    let all_ok = all (checkPageCRC ogg) pages
    printf "    %d tracks, %3d pages, %d bytes remain. CRC ok? %s\n" (length tracks) (length pages) (B.length rest) (show all_ok)

checkPageCRC :: B.ByteString -> OggPage -> Bool
checkPageCRC ogg page =
    let raw_page = B.take (fromIntegral (pageLength page)) $
                   B.drop (fromIntegral (pageOffset page)) $ ogg
        raw_page' = pageWrite page
    in raw_page == raw_page'
-}

prettyHex :: B.ByteString -> String
prettyHex = spaceout . map (printf "%02X") . B.unpack
  where spaceout (a:b:[]) = a ++ b
        spaceout (a:b:r) = a ++ b ++ " " ++ spaceout r
        spaceout r = concat r

forMn_ :: Monad m => [a] -> (Int -> a -> m b) -> m ()
forMn_ l f = forM_ (zip l [0..]) $ \(x,n) -> f n x

forMn :: Monad m => [a] -> (Int -> a -> m b) -> m [b]
forMn l f = forM (zip l [0..]) $ \(x,n) -> f n x

main = do
    args <- getArgs
    file <- case args of
        [file] -> return file
        _ -> do
            prg <- getProgName
            putStrLn $ "Usage: " ++ prg ++ " <file.gme>"
            exitFailure
    bytes <- B.readFile file

    -- Ogg file stuff
    let ato = runGet audioTableOffset bytes
        at = runGet (audioTable ato) bytes
        (oo,ol) = head at
        audio = runGet (extract oo ol) bytes
        x = runGet (getXor oo) bytes


    printf "Filename %s\n" file
    printf "File size: %08X (%d)\n" (B.length bytes) (B.length bytes)
    printf "Checksum found %08X, calculated %08X\n"
        (runGet (skip (fromIntegral (B.length bytes) - 4) >> getWord32le) bytes)
        (foldl' (+) 0 (map fromIntegral (B.unpack (B.take (B.length bytes -4) bytes))) :: Word32)
    printf "Audio table offset: %08X\n" ato
    printf "First Audio table offset entry: %08X %d\n" oo ol
    printf "XOR value: %02X\n" x
    printf "First Audio magic: %s\n" (show (B.take 4 audio))
    printf "First Audio magic xored: %s\n" (show (B.map (xor x) (B.take 4 audio)))

    (at, at_doubled) <-
        if take (length at `div` 2) at == drop (length at `div` 2) at
        then do
            printf "Audio table repeats itself! Ignoring first half.\n"
            return (take (length at `div` 2) at, True)
        else
            return (at, False)

    printf "Audio Table entries: %d\n" (length at)

    forMn_ at (checkAT bytes)

    createDirectoryIfMissing False "oggs"
    forMn_ at $ \n (oo,ol) -> do
        let rawaudio = runGet (extract oo ol) bytes
        let audio = decypher x rawaudio
        let audiotype = fromMaybe "raw" $ lookup (B.take 4 audio) fileMagics
        let filename = printf "oggs/%s_%04d.%s" file n audiotype
        if B.null audio
        then do
            printf "File %s would be empty...\n" filename
        else do
            B.writeFile filename audio
            printf "Dumped decyphered %s\n" filename

            -- when (x `B.elem` (B.take 58 rawogg)) $
            --    printf "Found XOR magic %02X in %s\n" x filename

            -- checkOgg ogg

    -- Other stuff

    let mto = runGet mainTableOffset bytes
        mt  = runGet (mainTable mto) bytes
    printf "Main table offset: %08X\n" mto
    printf "Main table entries: %d\n" (length mt)
    let fl = (findIndex (\x -> x /= 0xFFFFFFFF && x > ato) mt)
    mt <- case fl of
        Nothing -> return mt
        Just n -> do
            printf "First obviously wrong entry: %d, truncating\n" n
            return $ take n mt
    printf "Invalid main table entries: %d\n" (length (filter (== 0xFFFFFFFF) mt))
    -- printf "Large main table entries: %d\n" (length (filter (> ato) mt))
    printf "First two entries: %08X %08X\n" (mt !! 0) (mt !! 1)
    printf "Last entry: %08X\n" (last mt)

    let jtos = filter (< ato) $
               filter (/= 0xFFFFFFFF) (drop 2 mt)
    let jts = map (getJumpTable bytes) jtos

    printf "%d Jump tables follow:\n" (length jts)
    forM_ (zip jtos jts) $ \(o, jt) -> do
        printf "Jump table at %08X:\n" o
        forM_ jt $ \line -> do
            --printf "    %s\n" (prettyHex line)
            let l = parseLine line
            printf "    %s\n" (ppLine l)
            mapM_  (printf "     * %s\n") (checkLine (length at) l)

    forM_ hyps $ \(hyp, desc) -> do
        let wrong = filter (not. hyp) (concat jts)
        if null wrong
        then printf "All lines do satisfy hypothesis \"%s\"!\n" desc
        else do
            printf "These lines do not satisfy hypothesis \"%s\":\n" desc
            forM_ wrong $ \line -> do
                let l = parseLine line
                printf "    %s\n" (prettyHex line)
                printf "    %s\n" (ppLine l)

    let known_segments = sort $
            [ (0, 4, "Main table address") ] ++
            [ (4, 4, "Audio table address") ] ++
            [ (mto, fromIntegral (4 * length mt), "Main table") ] ++
            [ (jto, 2 + fromIntegral n * 4, "Jump table header") |
                jto <- jtos,
                let n = runGet (skip (fromIntegral jto) >> getWord16le) bytes
            ] ++
            [ (lo, n, "Jump table line") |
                jto <- jtos,
                lo <- getJumpTableOffsets bytes jto,
                let n = getJumpTableLineLength bytes lo
            ] ++
            [ (ato, fromIntegral (8 * length at), "Audio table") ] ++
            [ (ato + fromIntegral (8 * length at), fromIntegral (8 * length at), "Duplicated audio table") |
              at_doubled
            ] ++
            [ (o, fromIntegral l, "Audio file " ++ show n ) | (n,(o,l)) <- zip [0..] at ]++
            [ (fromIntegral (B.length bytes), 0, "End of file") ]
    let overlapping_segments =
            filter (\((o1,l1,_),(o2,l2,_)) -> o1+l1 > o2) $
            zip known_segments (tail known_segments)
    printf "Overlapping segments: %d\n"
        (length overlapping_segments)
    forM_ overlapping_segments $ \((o1,l1,d1),(o2,l2,d2)) ->
        printf "   Offset %08X Size %d (%s) overlaps Offset %08X Size %d (%s) by %d\n"
            o1 l1 d1 o2 l2 d2 (o1 + l1 - o2)
    let unknown_segments =
            filter (\(o,l) -> not
                (l == 2 && runGet (skip (fromIntegral o) >> getWord16le) bytes == 0)) $
            filter (\(o,l) -> l > 0) $
            zipWith (\(o1,l1,_) (o2,_,_) -> (o1+l1, o2-(o1+l1)))
            known_segments (tail known_segments)
    printf "Unknown file segments: %d (%d bytes total)\n"
        (length unknown_segments) (sum (map snd unknown_segments))
    forM_ unknown_segments $ \(o,l) ->
        printf "   Offset: %08X to %08X (%d bytes)\n" o (o+l) l


