{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module     : Test.QuickCheck.BLASBase
-- Copyright  : Copyright (c) , Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--

module Test.QuickCheck.BLASBase
    where
        
import Control.Monad
import Data.Maybe( fromJust )

import Test.QuickCheck hiding ( vector, elements )
import qualified Test.QuickCheck as QC

import Data.Vector.Dense( Vector, listVector, subvectorWithStride,
    conj )
import Data.Matrix.Dense( Matrix, listMatrix, herm, submatrix )
import Data.Matrix.Banded( Banded, maybeBandedFromMatrix )
import Data.Elem.BLAS

-- | Generate a list of elements suitable for testing with.
elements :: (Elem e, Arbitrary e) => Int -> Gen [e]
elements n = do
    es <- liftM (filter isTestableElem) $ QC.vector n
    let n' = length es
    if n' < n
        then liftM (es ++) $ elements (n-n')
        else return es

-- | Generate a list of elements for testing that have no imaginary part.
realElements :: (Elem e, Arbitrary e) => Int -> Gen [e]
realElements n = liftM (map fromReal) $ elements n

-- | Get an appropriate dimension for a random vector
dim :: Gen Int
dim = liftM abs arbitrary

-- | Generate a random vector of the given size.
vector :: (BLAS1 e, Arbitrary e) => Int -> Gen (Vector n e)
vector n =
    frequency [ (3, rawVector n)  
              , (2, conjVector n)
              , (1, subVector n    >>= \(SubVector s x o _) -> 
                    return $ subvectorWithStride s x o n)
              ]    

data SubVector n e = 
    SubVector Int 
              (Vector n e) 
              Int 
              Int 
    deriving (Show)

instance (Arbitrary e, BLAS1 e) => Arbitrary (SubVector n e) where
    arbitrary = sized $ \m -> 
        choose (0,m) >>= subVector
        
    coarbitrary = undefined

rawVector :: (BLAS1 e, Arbitrary e) => Int -> Gen (Vector n e)
rawVector n = do
    es <- elements n
    return $ listVector n es

conjVector :: (BLAS1 e, Arbitrary e) => Int -> Gen (Vector n e)
conjVector n = do
    x <- vector n
    return $ (conj x)

subVector :: (BLAS1 e, Arbitrary e) => Int -> Gen (SubVector n e)
subVector n = do
    o <- choose (0,5)
    s <- choose (1,5)
    e <- choose (0,5)
    x <- vector (o + s*n + e)
    return (SubVector s x o n)

data SubMatrix m n e = 
    SubMatrix (Matrix (m,n) e) 
              (Int,Int) 
              (Int,Int) 
    deriving (Show)

-- | Generate an appropriate shape for a random matrix.
shape :: Gen (Int,Int)
shape = sized $ \s ->
    let s' = (ceiling . sqrt) (fromIntegral s :: Double)
    in liftM2 (,) (choose (0,s')) (choose (0,1+s'))

-- | Generate a random matrix of the given shape.
matrix :: (BLAS3 e, Arbitrary e) => (Int,Int) -> Gen (Matrix (m,n) e)
matrix mn = frequency [ (3, rawMatrix mn)  
                      , (2, hermedMatrix mn)
                      , (1, subMatrix mn >>= \(SubMatrix a ij _) -> 
                                 return $ submatrix a ij mn)
                      ]

rawMatrix :: (BLAS3 e, Arbitrary e) => (Int,Int) -> Gen (Matrix (m,n) e)
rawMatrix (m,n) = do
    es <- elements (m*n)
    return $ listMatrix (m,n) es

hermedMatrix :: (BLAS3 e, Arbitrary e) => (Int,Int) -> Gen (Matrix (m,n) e)
hermedMatrix (m,n) = do
    x <- matrix (n,m)
    return $ (herm x)

subMatrix :: (BLAS3 e, Arbitrary e) => (Int,Int) -> Gen (SubMatrix m n e)
subMatrix (m,n) = 
    oneof [ rawSubMatrix (m,n)
          , rawSubMatrix (n,m) >>= \(SubMatrix a (i,j) (m',n')) ->
                return $ SubMatrix (herm a) (j,i) (n',m')
          ]

rawSubMatrix :: (BLAS3 e, Arbitrary e) => (Int,Int) -> Gen (SubMatrix m n e)
rawSubMatrix (m,n) = do
    i <- choose (0,5)
    j <- choose (0,5)
    e <- choose (0,5)
    f <- choose (0,5)
    x <- rawMatrix (i+m+e, j+n+f)
    return $ SubMatrix x (i,j) (m,n)

instance (Arbitrary e, BLAS3 e) => Arbitrary (SubMatrix m n e) where
    arbitrary = do
        (m,n) <- shape
        (SubMatrix a ij mn) <- subMatrix (m,n)
        return $ SubMatrix a ij mn
        
    coarbitrary = undefined

-- | Generate valid bandwidth for a given matrix dimension size
bandwidth :: Int -> Gen Int
bandwidth n = if n == 0 then return 0 else choose (0,n-1)
    
-- | Generate valid bandwidths for the given matrix shape.
bandwidths :: (Int,Int) -> Gen (Int,Int)
bandwidths (m,n) = liftM2 (,) (bandwidth m) (bandwidth n)

-- | Generate a random banded matrix.
banded :: (BLAS3 e, Arbitrary e) => 
    (Int,Int) -> (Int,Int) -> Gen (Banded (m,n) e)
banded mn lu = frequency [ (3, rawBanded mn lu)  
                         , (2, hermedBanded mn lu)
                         ]

rawBanded :: (BLAS3 e, Arbitrary e) => 
    (Int,Int) -> (Int,Int) -> Gen (Banded (m,n) e)
rawBanded (m,n) (kl,ku) = 
    let bw = kl+ku+1
    in do
        a <- frequency [ (2, rawMatrix (bw,n))
                       , (1, rawSubMatrix (bw,n) >>= \(SubMatrix b ij _) ->
                                 return $ submatrix b ij (bw,n))     
                       ]
        return $ fromJust (maybeBandedFromMatrix (m,n) (kl,ku) a)

hermedBanded :: (BLAS3 e, Arbitrary e) => 
    (Int,Int) -> (Int,Int) -> Gen (Banded (m,n) e)
hermedBanded (m,n) (kl,ku) = do
    x <- rawBanded (n,m) (ku,kl)
    return $ herm x


