module Statistics (
    tests_Statistics
    ) where

import Control.Monad( replicateM )
import Data.AEq
import Data.List( foldl' )
import Debug.Trace
import Test.Framework
import Test.Framework.Providers.QuickCheck2
import Test.QuickCheck hiding ( vector )
import qualified Test.QuickCheck as QC

import Numeric.LinearAlgebra

import Test.QuickCheck.LinearAlgebra( VectorList(..), WeightedVectorList(..) )
import qualified Test.QuickCheck.LinearAlgebra as Test

import Typed

testAEq actual expected =
    if actual ~== expected
        then True
        else trace ("expected: " ++ show expected ++ "\nactual: " ++ show actual)
                   False



tests_Statistics = testGroup "Statistics"
    [ testPropertyD "sumVector" prop_sumVector
    , testPropertyD "weightedSumVector" prop_weightedSumVector
    , testPropertyD "meanVector" prop_meanVector
    , testPropertyD "weightedMeanVector" prop_weightedMeanVector
    , testPropertyD "weightedMeanVector (equal weights)" prop_weightedMeanVector_eqw
    , testPropertyD "covMatrix" prop_covMatrix
    , testPropertyD "covMatrixWithMean" prop_covMatrixWithMean
    , testPropertyD "weightedCovMatrix (equal weights)" prop_weightedCovMatrix_eqw
    , testPropertyD "weightedCovMatrix" prop_weightedCovMatrix
    , testPropertyD "weightedCovMatrixWithMean" prop_weightedCovMatrixWithMean
    ]


prop_sumVector t (VectorList p xs) =
    sumVector p xs ~== foldl' addVector (constantVector p 0) xs
  where
    _ = typed t (head xs)

prop_weightedSumVector t (WeightedVectorList p wxs) =
    weightedSumVector p wxs
            ~== sumVector p (map (uncurry scaleVector) wxs)
  where
    n = length wxs
    _ = typed t (snd $ head wxs)

prop_meanVector t (VectorList p xs) =
    meanVector p xs ~== scaleVector (1/n) (sumVector p xs)
  where
    n = fromIntegral $ max (length xs) 1
    _ = typed t (head xs)

prop_weightedMeanVector_eqw t (VectorList p xs) = let
    wxs = zip (repeat 1) xs
    in weightedMeanVector p wxs ~== meanVector p xs
  where
    _ = typed t (head xs)
    
prop_weightedMeanVector t (WeightedVectorList p wxs) = let
        w_sum = (sum . fst . unzip) wxs
        in weightedMeanVector p wxs
            ~== if w_sum == 0 then constantVector p 0
                              else scaleVector (1/w_sum) (weightedSumVector p wxs)
  where
    n = length wxs
    _ = typed t (snd $ head wxs)

prop_covMatrix t (VectorList p xs) =
    forAll (Test.vector p) $ \z ->
    forAll (elements [ UnbiasedCov, MLCov ]) $ \method -> let
        xbar = meanVector p xs
        ys = [ subVector x xbar | x <- xs ]
        scale = case method of { UnbiasedCov -> 1/(n-1) ; MLCov -> 1/n }
        cov' = foldl' (flip $ \y -> rank1UpdateMatrix scale y y)
                      (constantMatrix (p,p) 0)
                      ys
        cov = covMatrix p method xs

        in mulHermMatrixVector cov z ~== mulMatrixVector NoTrans cov' z
  where
    n = fromIntegral $ length xs
    _ = typed t $ head xs

prop_covMatrixWithMean t (VectorList p xs) =
    forAll (Test.vector p) $ \z ->
    forAll (elements [ UnbiasedCov, MLCov ]) $ \method -> let
        xbar = meanVector p xs
        cov' = covMatrixWithMean xbar method xs
        cov = covMatrix p method xs
        in mulHermMatrixVector cov z ~== mulHermMatrixVector cov' z
  where
    n = fromIntegral $ length xs
    _ = typed t $ head xs

prop_weightedCovMatrix_eqw t (VectorList p xs) =
    forAll (Test.vector p) $ \z ->
    forAll (elements [ UnbiasedCov, MLCov ]) $ \method -> let
        wxs = zip (repeat 1) xs
        cov = weightedCovMatrix p method wxs
        cov' = covMatrix p method xs
        in mulHermMatrixVector cov z ~== mulHermMatrixVector cov' z
  where
    n = fromIntegral $ length xs
    _ = typed t $ head xs

prop_weightedCovMatrix t (WeightedVectorList p wxs) =
    forAll (Test.vector p) $ \z ->
    forAll (elements [ UnbiasedCov, MLCov ]) $ \method -> let
        (ws,xs) = unzip wxs
        
        w_sum = sum ws
        ws' = [ w / w_sum | w <- ws ]
        w2_sum = sum [ w*w | w <- ws' ]
        scale = case method of { UnbiasedCov -> 1/(1-w2_sum) ; MLCov -> 1 }

        xbar = weightedMeanVector p wxs
        wys = [ (w, subVector x xbar) | (w,x) <- zip ws' xs ]
        cov' = if w_sum == 0
                    then constantMatrix (p,p) 0
                    else foldl' (flip $ \(w,y) -> rank1UpdateMatrix (scale*w) y y)
                                (constantMatrix (p,p) 0)
                                wys

        cov = weightedCovMatrix p method wxs

        in mulHermMatrixVector cov z ~== mulMatrixVector NoTrans cov' z
  where
    n = fromIntegral $ length wxs
    _ = typed t $ snd $ head wxs

prop_weightedCovMatrixWithMean t (WeightedVectorList p wxs) =
    forAll (Test.vector p) $ \z ->
    forAll (elements [ UnbiasedCov, MLCov ]) $ \method -> let
        xbar = weightedMeanVector p wxs
        cov' = weightedCovMatrix p method wxs
        cov = weightedCovMatrixWithMean xbar method wxs
        in mulHermMatrixVector cov z ~== mulHermMatrixVector cov' z
  where
    n = fromIntegral $ length wxs
    _ = typed t $ snd $ head wxs