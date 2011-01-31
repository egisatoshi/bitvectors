{-# LANGUAGE FlexibleContexts, StandaloneDeriving #-}

module Static2 where

import Encoding2 hiding ((+++))
import Util
import Measure
import BitVector
import Testing

import Data.Array.Unboxed
import Data.Word
import Data.Int
import Data.List

import Test.QuickCheck

type V = UArray Int

type Big = Int
type Small = Int16

data SuccinctArray =
  SuccinctArray
  {stride :: !Int,
   big :: !(V Big),
   small :: !(V Small)}
  deriving Show

(!-) :: SuccinctArray -> Int -> Big
(SuccinctArray stride big small) !- i =
  base + fromIntegral offset
  where (bigI,smallI) = i `divMod` stride
        base = big ! bigI
        offset = small ! (bigI*stride + smallI)

mkSuccinctArray :: 
  Int -> [Big] -> SuccinctArray
mkSuccinctArray stride vals =
  SuccinctArray stride big small
    where (bigs,smalls) = loop 0 [] [] vals
          small = listArray' (length smalls) smalls
          big =   listArray' (length bigs)   bigs
          a -. b = fromIntegral (a - b)
          loop _    bigs smalls []       = (reverse bigs,reverse smalls)
          loop 0    bigs smalls (v:vals) =
            loop (stride-1) (v:bigs) (0:smalls) vals
          loop left bigs smalls (v:vals) =
            loop (left-1) bigs ((v -. head bigs) : smalls) vals

prop_SuccinctArray :: Property
prop_SuccinctArray =
  forAll (listOf1 suitable) $ \vals ->
  forAll (choose (1,length vals)) $ \stride ->
  forAll (choose (0,length vals-1)) $ \i ->
  let vals' = map fromIntegral (vals :: [Small])
  in vals' !! i == mkSuccinctArray stride vals' !- i
    where 
      suitable = fmap (`div` 4) arbitrary


data Static =
  Static {sbitlength :: !Int,
          compressed :: !Block,
          blockSize :: !Int,
          ranks :: !SuccinctArray,      -- i -> rank(B,i*blockSize)
          locations :: !SuccinctArray,  -- \ mapping from unencoded locations
          offsets :: !SuccinctArray     -- / to encoded locations
         }
  deriving Show
  
  
mkStatic n bs = 
  let blockSize = ilog2 n
      stride = ilog2 n
      compressed = makeBlock . eliasEncode . gapify $ bs
      p = process blockSize compressed
      (encposes,offsets,sizeranks) = unzip3 p
      ranks = map getRank sizeranks
      
      mkArr = mkSuccinctArray stride . map fromIntegral
          
  in Static
     n
     compressed
     blockSize
     (mkArr ranks)
     (mkArr encposes)
     (mkArr offsets)
          
process :: Int
           -> Block
           -> [(Int,Int,SizeRank)]  -- [(encpos,offset,sr)]
process stride block = format 0 (SizeRank 0 0) 0 $ loop 0 (SizeRank 0 0)
  where loop i acc =
          case readElias block i
          of
            Nothing -> [(i,acc)]
            Just (gap,i') -> let acc' = acc +++ measure gap
                             in (i,acc):loop i' acc'
                                
        format :: Int->SizeRank->Int->[(Int,SizeRank)]->[(Int,Int,SizeRank)]
        format _      _   _      []                   = []
        format encpos sr nextpos (x@(encpos',sr'):xs)
          | siz' > nextpos = (encpos,offset,sr)
                             : format encpos sr (nextpos+stride) (x:xs)
          | otherwise = format encpos' sr' nextpos xs
            where 
              siz  = getSize sr
              siz' = getSize sr'
              offset = nextpos-siz

---

_query :: Static -> Int -> Bool
_query static i = 
  let arrayIndex = i `div` blockSize static
      -- i' is the index for which we can get location and offset values
      i' = arrayIndex * blockSize static
      -- we start decoding here
      location = locations static !- arrayIndex
      -- total number of bits to skip from decoded stream
      offset = (offsets static !- arrayIndex) + (i-i')
      gaps = readEliass' (compressed static) location
  in
   query gaps offset
   
_queryrank :: Static -> Int -> Int
_queryrank static i =
  let arrayIndex = i `div` blockSize static
      i' = arrayIndex * blockSize static
      location = locations static !- arrayIndex
      offset = (offsets static !- arrayIndex) + (i-i')
      baseRank = ranks static !- arrayIndex
      gaps = readEliass' (compressed static) location
  in
   baseRank + queryrank gaps offset
          

prop_s_query =
  meta_bitvector (construct' :: [Bool] -> Static) query query
prop_s_queryrank = 
  meta_bitvector (construct' :: [Bool] -> Static) queryrank queryrank
  
instance BitVector Static where
  query = _query
  queryrank = _queryrank
  select = undefined
  construct = mkStatic
  querysize = sbitlength