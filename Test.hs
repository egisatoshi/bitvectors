module Main where

import Util
import Testing
import Static
import BitVector
import FingerTreeDynamic 
import Encoding2 (EBlock,UBlock,NBlock)
import Static2
import Tree (Dynamic,SmallDynamic,SmallEliasDynamic)
import SmallBlock

import qualified Data.ByteString as B
import Data.Char
import System.Environment (getArgs)
import Data.Array.Unboxed
import Random
import Control.Monad

gen n = cycle $ True : replicate (n-1) False

gen2 n k = map f . take n $ randoms (mkStdGen 0)
  where 
    f :: Int -> Bool
    f a = a `mod` k == 0
  
main = do

  s:filename:k':_ <- getArgs

  let k = read k'

  --let input = take n $ gen2 37
  --let input0 = gen2 1024 37
  --let input = take n $ cycle input0
  
  input <- bitsFromFile filename
  let n = length input
  
  print (s,filename,n,k)

  case s of --"so" -> test (staticVector_ord n input) n k
            "sg" -> test (staticVector_gap n input) n k
            "s2" -> test (mkStatic n input) n k
            "fd" -> test (construct n input :: FDynamic EBlock) n k
            "fdn"-> test (construct n input :: FDynamic NBlock) n k
            "fun"-> test (construct n input :: FDynamic UBlock) n k
            "fs" -> test (construct n input :: FDynamic SmallBlock) n k
            "fse" -> test (construct n input :: FDynamic SmallElias) n k
            "d"  -> test (construct n input :: Dynamic EBlock) n k
            "dn"  -> test (construct n input :: Dynamic NBlock) n k
            "ds" -> test (construct n input :: SmallDynamic) n k
            "dse"-> test (construct n input :: SmallEliasDynamic) n k


