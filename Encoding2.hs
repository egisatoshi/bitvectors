{-# LANGUAGE RankNTypes,BangPatterns,FlexibleInstances,MultiParamTypeClasses #-}

module Encoding2
  where

import Data.List (isPrefixOf,unfoldr)
import Numeric (showHex)
import Data.Bits
import Data.Bits.Extras
import Data.Word
import Control.Monad.ST
import Data.Array.Unboxed
import Data.Array.ST

import Debug.Trace

import Test.QuickCheck hiding ((.&.))
                              
import Measure (SizeRank(..))
import Data.FingerTree (Measured(..))
  
import Data.Monoid

import Util
import BitVector

-- A Code is a smallish chunk of bits
data Code = Code {codelength :: !Word8, code :: !Word64}

instance Eq Code where
  a == b = codelength a == codelength b && getCode a == getCode b

codelengthG = fromIntegral . codelength

getCode (Code len code) = code .&. ones (fromIntegral len)

instance Show Code where
  show (Code len code) = "Code " ++ show len ++ " " ++ showHex code ""

codeToBits :: Code -> [Bool]
codeToBits (Code len code) =
  map (testBit code) [0..fromIntegral len-1]
    
bitsToCode :: [Bool] -> Code
bitsToCode bs = Code (fromIntegral len) w
  where len = length bs
        w = fromIntegral . unbitify $ bs
        
prop_codeToBits =
  forAll (choose (0,63)) $ \siz ->
  forAll (vector siz) $ \bits ->
  codeToBits (bitsToCode bits) == bits
  
(+++) :: Code -> Code -> Code
a +++ b
  | codelength a + codelength b > 64 = error "out of space"
  | otherwise = Code
                (codelength a + codelength b)
                (shiftL (getCode b) (fromIntegral $ codelength a)
                 .|. getCode a)
                
takeCode :: Int -> Code -> Code
takeCode a (Code l c) = Code (fromIntegral a `min` l) (c .&. ones a)

minus' :: (Ord a, Num a) => a -> a -> a
minus' x y | y>x       = 0
           | otherwise = x-y
dropCode a (Code l c) = Code (minus' l (fromIntegral a)) (c `shiftR` a)

prop_plusplusplus :: Code -> Code -> Bool
prop_plusplusplus a b 
  | codelength a + codelength b > 64 = True
  | otherwise = codeToBits (a+++b) == codeToBits a ++ codeToBits b
  
prop_takeCode c = 
  forAll (choose (0,70)) $ \n ->
  codeToBits (takeCode n c) == take n (codeToBits c)
  
prop_dropCode c = 
  forAll (choose (0,70)) $ \n ->
  codeToBits (dropCode n c) == drop n (codeToBits c)

                
instance Arbitrary Code where
  arbitrary = do code <- fmap fromIntegral (arbitrary :: Gen Integer)
                 codelength <- fmap fromIntegral (choose (0,64) :: Gen Integer)
                 return (Code codelength code)
  shrink (Code len code) = do l <- shrink len
                              return (Code l code)

{-# SPECIALIZE ones :: Int -> Word8 #-}
{-# SPECIALIZE ones :: Int -> Word64 #-}
ones :: Bits a => Int -> a
ones i = setBit 0 i - 1

elias_encode :: Gap -> Code
elias_encode (Gap 0) = Code 1 1
elias_encode (Gap i)
  | l+ll+ll-1 > 64 = error "number too big for elias_encode"
  | otherwise = code
  where l  = ilog2 i
        ll = ilog2 l
        icode  = Code (fromIntegral $ l-1)  (fromIntegral i .&. ones (l-1))
        lcode  = Code (fromIntegral $ ll-1) (fromIntegral l .&. ones (ll-1))
        llcode = Code (fromIntegral $ ll) 0
        one    = Code 1 1
        code = llcode +++ one +++ lcode +++ icode
        
prop_elias_encode_0 =
  elias_encode (Gap 0) == Code 1 1
prop_elias_encode_1 =
  elias_encode (Gap 1) == bitsToCode [False,True]
prop_elias_encode_2 =
  elias_encode (Gap 2) == bitsToCode [False,False,True,False,False]
prop_elias_encode_17 =
  elias_encode (Gap 17) == bitsToCode ([False,False,False,True]
                                       ++[True,False]
                                       ++[True,False,False,False])

        
newtype Block = Block (UArray Int Word8)

instance Arbitrary Block where
  arbitrary = do xs <- listOf1 arbitrary
                 return . Block $ listArray' (length xs) xs

instance Show Block where
  show (Block a) = "Block " ++ concatMap s (elems a)
    where 
      s :: Word8 -> String
      s w = showHex w "" ++ ";"

blockToBits :: Block -> [Bool]
blockToBits (Block arr) = concatMap f (elems arr)
  where f w = map (testBit w) [0..7]

bitLength :: Block -> Int
bitLength (Block arr) = 8 * (snd (bounds arr) + 1)

prop_bitLength :: Block -> Bool
prop_bitLength b = length (blockToBits b) == bitLength b

writeCode :: (forall s. STUArray s Int Word8 -> Int -> Code -> ST s Int)
writeCode arr index (Code 0 _) = return index
writeCode arr index c =
  do let (wordIndex,bitIndex) = index `divMod` 8
     word <- readArray arr wordIndex
     -- [64-length][nWrite][length-nWrite]
     -- => [64-nWrite][nWrite]
     -- => [bitIndex][nWrite][8-bitIndex-nWrite]
     let length = codelengthG c
         nWrite = min (8-bitIndex) length
         toWrite = fromIntegral . getCode $ takeCode nWrite c
         shifted = toWrite `shiftL` bitIndex
     -- XXX overwriting doesn't work!
     writeArray arr wordIndex (word .|. shifted)
     --trace (show ("XX",shifted,toWrite,wordIndex,bitIndex)) $
     writeCode arr (index+nWrite) (dropCode nWrite c)
     

makeBlock :: [Code] -> Block
makeBlock codes = Block array
  where 
    len = sum (map (fromIntegral.codelength) codes) `mydiv` 8
    array = runSTUArray $
                do arr <- newArray_ (0,len-1)
                   let loop [] _     = return ()
                       loop (c:cs) i = do i' <- writeCode arr i c
                                          loop cs i'
                   loop codes 0
                   return arr

prop_makeBlock :: [Code] -> Bool
prop_makeBlock codes = bits `isPrefixOf` bits'
  where block = makeBlock codes
        bits' = blockToBits block
        bits = concatMap codeToBits codes


word8ToCode :: Word8 -> Code
word8ToCode w = Code 8 (fromIntegral w)
                 
readPiece :: Block -> Int -> Code
readPiece b@(Block arr) index = code
  where (wordIndex,bitIndex) = index `divMod` 8
        code = dropCode bitIndex $ word8ToCode (arr!wordIndex)
                  
prop_readPiece block =
  forAll (choose (0,bitLength block-1)) $ \i ->
    codeToBits (readPiece block i) `isPrefixOf` drop i (blockToBits block)

readCode :: Block -> Int -> Int -> Code
readCode b index len = loop (Code 0 0) index realLen
  where 
    realLen = min len (bitLength b - index)
    loop c _     0   = c
    loop c index len 
          = let p = readPiece b index
                c' = takeCode len p
                l = codelengthG c'
            in loop (c+++c') (index + l) (len - l)
       
prop_readCode block =
  forAll (choose (0,bitLength block-1)) $ \i ->
    forAll (choose (0,64)) $ \len ->
      codeToBits (readCode block i len) 
      == (take len . drop i $ blockToBits block)

prop_write_read_code :: Code -> Bool
prop_write_read_code c =
  c == readCode (makeBlock [c]) 0 (fromIntegral $ codelength c)
  
myTrailingZeros :: Code -> Maybe Int
myTrailingZeros c = if getCode c == 0
                    then Nothing 
                    else Just (fromIntegral $ trailingZeros (getCode c))

readElias :: Block -> Int -> Maybe (Gap,Int)
readElias b index =
  let code = (readCode b index 64)
  in case myTrailingZeros code
     of Nothing -> Nothing
        Just 0 -> Just (Gap 0,index+1)
        Just ll ->
          let lPart = dropCode (ll+1) code
              lCode = takeCode (ll-1) lPart +++ Code 1 1
              l = fromIntegral $ getCode lCode
              xPart = dropCode (ll-1) lPart
              almost = takeCode (l-1) xPart
              final = almost +++ Code 1 1
          in Just (Gap . fromIntegral . getCode $ final,
                   index+2*ll+l-1)
    
    
prop_read_write_elias = 
  forAll (choose (0,8007199254740992)) $ \i -> 
    let g = Gap i
        code = elias_encode g
        block = makeBlock [code]
        Just (out,len) = readElias block 0
    in (g == out && len == fromIntegral (codelength code))

readEliass' :: Block -> Int -> [Gap]
readEliass' block = unfoldr (readElias block)
                    
readEliass block = readEliass' block 0                    

prop_read_eliass =
  forAll (listOf1 $ choose (0,8007199254740992)) $ \is ->
    let gs = map Gap is
    in gs == (readEliass . makeBlock . map elias_encode) gs

gapEncode_ :: (Gap->Code) -> Code -> [Gap] -> [Code]
gapEncode_ enc terminator gs = loop gs 
  where
    loop []     = [terminator]
    loop (g:gs) = enc g : loop gs
    
eliasEncode :: [Gap] -> [Code]
eliasEncode = gapEncode_ elias_encode (Code 0 0)

----


nibble_encode :: Gap -> Code
nibble_encode (Gap i)
  | i<2^3 = Code 4 (fromIntegral i)
  | otherwise = go base (shiftR (fromIntegral i) 3)
    where base = Code 4 (fromIntegral i .&. ones 3)
          snip i = Code 4 (setBit 0 3 .|. i .&. ones 3)
          go acc 0 = acc 
          go acc i = go (snip i +++ acc) (shiftR i 3)

nibbleTerminator :: Int
nibbleTerminator = 8

nibbleTerminatorCode :: Code
nibbleTerminatorCode = Code 4 8

nibble :: Block -> Int -> Int
nibble b i = fromIntegral $ getCode $ takeCode 4 $ readPiece b i

readNibble :: Block -> Int -> Maybe (Gap,Int)
readNibble b i = if nibble b i == 8
                 then Nothing
                 else loop 0 i
  where loop !acc !i =
          let n = nibble b i
              value = n .&. ones 3
              acc' = (acc `shiftL` 3) .|. value
          in case testBit n 3 of
            False -> Just (Gap acc',i+4)
            True -> loop acc' (i+4)
            
prop_nibble = 
  forAll (choose (0,2^30)) $ \i ->
    let Just (Gap j,_) = readNibble (makeBlock [nibble_encode (Gap i)]) 0
    in j == i
       
readNibbles :: Block -> [Gap]
readNibbles block = unfoldr (readNibble block) 0

prop_readNibbles =
  forAll (listOf1 $ choose (0,2^30)) $ \is ->
    let gs = map Gap is
        out = (readNibbles 
               . makeBlock
               . (++[nibbleTerminatorCode])
               . map nibble_encode) gs
    in gs == out

nibbleEncode = gapEncode_ nibble_encode nibbleTerminatorCode

{-
elias_decode :: Code -> Int
elias_decode (Code length code) = if ll == 0 then 0 else i
  where ll = leadingZeros code - (64-length)
  -}
-----


-----

data EBlock = EBlock {emeasure :: !SizeRank,
                      unEBlock :: !Block}
data NBlock = NBlock {nmeasure :: !SizeRank,
                      unNBlock :: !Block}
data UBlock = UBlock {umeasure :: !SizeRank,
                      unUBlock :: !Block}

class Encoded a where
  decode :: a -> [Gap]
  encode :: [Gap] -> a
  encodedSize :: a -> Int
  
  combine :: a -> a -> a
  combine x y = encode $ concatGaps (decode x) (decode y)
  
  cleave :: a -> (a,a)
  cleave b = let (x,y) = splitGaps (decode b)
             in (encode x, encode y)
  

instance Encoded EBlock where
  decode = readEliass . unEBlock
  encode g = EBlock (measure g) . makeBlock . eliasEncode $ g
  encodedSize = bitLength . unEBlock
  
instance Encoded NBlock where
  decode = readNibbles . unNBlock
  encode g = NBlock (measure g) . makeBlock . nibbleEncode $ g
  encodedSize = bitLength . unNBlock
  
instance Encoded UBlock where
  decode = gapify . deconstruct 
  --- XXX 0 is ugly!
  encode = construct 0 . unGapify 
  encodedSize = getSize . umeasure
      
instance Measured SizeRank EBlock where
  measure = emeasure

instance Measured SizeRank NBlock where
  measure = nmeasure
         
--- XXX could be more efficient
instance Measured SizeRank UBlock where
  measure = umeasure
    
       

instance BitVector EBlock where
  construct _ = encode . gapify
  query     (EBlock _ b) i = query (readEliass b) i
  queryrank (EBlock _ b) i = queryrank (readEliass b) i
  select    (EBlock _ b) i = select (readEliass b) i
  querysize = querysize . readEliass . unEBlock
  deconstruct = unGapify . readEliass . unEBlock
  
instance DynamicBitVector EBlock where
  -- XXX these recalculate the measure
  insert (EBlock _ b) i val = encode newGaps
    where newGaps = insert (readEliass b) i val
  delete (EBlock _ b) i = encode newGaps
    where newGaps = delete (readEliass b) i

instance BitVector NBlock where
  construct _ = encode . gapify
  query     (NBlock _ b) i = query (readNibbles b) i
  queryrank (NBlock _ b) i = queryrank (readNibbles b) i
  select    (NBlock _ b) i = select (readNibbles b) i
  querysize = querysize . readEliass . unNBlock
  deconstruct = unGapify . readEliass . unNBlock

  
instance DynamicBitVector NBlock where
  -- XXX these recalculate the measure
  insert (NBlock _ b) i val = encode newGaps
    where newGaps = insert (readNibbles b) i val
  delete (NBlock _ b) i = encode newGaps
    where newGaps = delete (readNibbles b) i
  
instance BitVector UBlock where
  construct _ xs = UBlock (measure xs) . makeBlock . map f . cut 64 $ xs
    where
      f xs = Code (fromIntegral $ length xs)
                  (fromIntegral . unbitify . reverse $ xs)
  query b i = query (decode b) i
  queryrank b i = queryrank (decode b) i
  select b i = select (decode b) i
  querysize = getSize . umeasure
  deconstruct b = take (querysize b) . blockToBits . unUBlock $ b