{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, FlexibleInstances #-}
{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module     : Data.Vector.Dense.Base
-- Copyright  : Copyright (c) , Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--

module Data.Vector.Dense.Base
    where

import Control.Monad
import Control.Monad.ST
import Data.AEq
import Foreign
import Unsafe.Coerce

import BLAS.Internal( checkBinaryOp, clearArray, inlinePerformIO,
    checkedSubvector, checkedSubvectorWithStride, checkVecVecOp )

import Data.Elem.BLAS ( Complex, Elem, BLAS1, conjugate )
import qualified Data.Elem.BLAS as BLAS

import Data.Tensor.Class
import Data.Tensor.Class.ITensor
import Data.Tensor.Class.MTensor

import Data.Vector.Dense.IOBase

infixl 7 <.>

-- | Immutable dense vectors. The type arguments are as follows:
--
--     * @n@: a phantom type for the dimension of the vector
--
--     * @e@: the element type of the vector.  Only certain element types
--       are supported.
--
newtype Vector n e = Vector (IOVector n e)

freezeIOVector :: (BLAS1 e) => IOVector n e -> IO (Vector n e)
freezeIOVector x = do
    y <- newCopyIOVector x
    return (Vector y)

thawIOVector :: (BLAS1 e) => Vector n e -> IO (IOVector n e)
thawIOVector (Vector x) =
    newCopyIOVector x

unsafeFreezeIOVector :: IOVector n e -> IO (Vector n e)
unsafeFreezeIOVector = return . Vector

unsafeThawIOVector :: Vector n e -> IO (IOVector n e)
unsafeThawIOVector (Vector x) = return x

-- | Common functionality between all vector types.
class (Shaped x Int e, Elem e) => BaseVector x e where
    -- | Get the dimension (length) of the vector.
    dim :: x n e -> Int
    
    -- | Get the memory stride (in elements) between consecutive elements.
    stride :: x n e -> Int

    -- | Indicate whether or not the vector stores the complex conjugates
    -- of its elements.
    isConj :: x n e -> Bool

    -- | Get a view into the complex conjugate of a vector.
    conj :: x n e -> x n e

    -- | Cast the shape type of the vector.
    coerceVector :: x n e -> x n' e
    coerceVector = unsafeCoerce
    {-# INLINE coerceVector #-}

    unsafeSubvectorViewWithStride :: Int -> x n e -> Int -> Int -> x n' e

    withVectorPtrIO :: x n e -> (Ptr e -> IO a) -> IO a
    unsafeIOVectorToVector :: IOVector n e -> x n e
    unsafeVectorToIOVector :: x n e -> IOVector n e

-- | An overloaded interface for vectors that can be read or created in
-- a monad.
class (BaseVector x e, BLAS1 e, Monad m, ReadTensor x Int e m) => ReadVector x e m where
    -- | Creates a new vector of the given length.  The elements will be 
    -- uninitialized.
    newVector_ :: Int -> m (x n e)

    -- | Execture an @IO@ action with a pointer to the first element and then
    -- convert the @IO@ action to an action in the monad @m@.
    withVectorPtr :: x n e -> (Ptr e -> IO a) -> m a

    -- | Convert a mutable vector to an immutable one by taking a complete
    -- copy of it.
    freezeVector :: x n e -> m (Vector n e)

    -- | Convert an immutable vector to a mutable one by taking a complete
    -- copy of it.
    thawVector :: Vector n e -> m (x n e)

    unsafeFreezeVector :: x n e -> m (Vector n e)
    unsafeThawVector :: Vector n e -> m (x n e)

-- | An overloaded interface for vectors that can be modified in a monad.
class (ReadVector x e m, WriteTensor x Int e m) => WriteVector x e m where

-- | Creates a new vector with the given association list.  Unspecified
-- indices will get initialized to zero.
newVector :: (ReadVector x e m) => Int -> [(Int,e)] -> m (x n e)
newVector n ies = do
    x <- newZeroVector n
    withVectorPtr x $ \p ->
        forM_ ies $ \(i,e) -> do
            when (i < 0 || i >= n) $ fail $
                "Index `" ++ show i ++ 
                    "' is invalid for a vector with dimension `" ++ show n ++
                    "'"
            pokeElemOff p i e
    return x
{-# INLINE newVector #-}

unsafeNewVector :: (ReadVector x e m) => Int -> [(Int,e)] -> m (x n e)
unsafeNewVector n ies = do
    x <- newZeroVector n
    withVectorPtr x $ \p ->
        forM_ ies $ \(i,e) -> do
            pokeElemOff p i e
    return x
{-# INLINE unsafeNewVector #-}

-- | Creates a new vector of the given dimension with the given elements.
-- If the list has length less than the passed-in dimenson, the tail of
-- the vector will be uninitialized.
newListVector :: (ReadVector x e m) => Int -> [e] -> m (x n e)
newListVector n es = do
    x <- newVector_ n
    withVectorPtr x $ \p ->
        pokeArray p $ take n $ es ++ (repeat 0)
    return x
{-# INLINE newListVector #-}

-- | Create a zero vector of the specified length.
newZeroVector :: (ReadVector x e m) => Int -> m (x n e)
newZeroVector n = do
    x <- newVector_ n
    withVectorPtr x $ \p ->
        clearArray p n
    return x
{-# INLINE newZeroVector #-}

-- | Set every element in the vector to zero.
setZeroVector :: (WriteVector x e m) => x n e -> m ()
setZeroVector = setZero
{-# INLINE setZeroVector #-}

-- | Create a vector with every element initialized to the same value.
newConstantVector :: (ReadVector x e m) => Int -> e -> m (x n e)
newConstantVector n e = do
    x <- newVector_ n
    withVectorPtr x $ \p ->
        pokeArray p (replicate n e)
    return x
{-# INLINE newConstantVector #-}

-- | Set every element in the vector to a constant.
setConstantVector :: (WriteVector x e m) => e -> x n e -> m ()
setConstantVector = setConstant
{-# INLINE setConstantVector #-}

-- | @newBasisVector n i@ creates a vector of length @n@ that is all zero 
-- except for at position @i@, where it equal to one.
newBasisVector :: (ReadVector x e m) => Int -> Int -> m (x n e)
newBasisVector n i = do
    x <- newZeroVector n
    withVectorPtr x $ \p ->
        pokeElemOff p i 1
    return x
{-# INLINE newBasisVector #-}

-- | @setBasis x i@ sets the @i@th coordinate of @x@ to @1@, and all other
-- coordinates to @0@.  If the vector has been scaled, it is possible that
-- @readVector x i@ will not return exactly @1@.  See 'setElem'.
setBasisVector :: (WriteVector x e m) => Int -> x n e -> m ()
setBasisVector i x
    | i < 0 || i >= dim x =
        fail $ "tried to set a vector of dimension `" ++ show (dim x) ++ "'"
               ++ " to basis vector `" ++ show i ++ "'"
    | otherwise = do
        setZeroVector x
        unsafeWriteElem x i 1 
{-# INLINE setBasisVector #-}

-- | Creates a new vector by copying another one.
newCopyVector :: (ReadVector x e m, ReadVector y e m) =>
    x n e -> m (y n e)
newCopyVector x
    | isConj x =
        newCopyVector (conj x) >>= return . conj
    | otherwise = do
        y <- newVector_ n
        withVectorPtr x $ \pX ->
            withVectorPtrIO y $ \pY ->
                BLAS.copy n pX incX pY 1
        return y
  where
    n    = dim x
    incX = stride x
{-# INLINE newCopyVector #-}

-- | Creates a new vector by copying another one.  The returned vector
-- is gauranteed not to be a view into another vector.  That is, the
-- returned vector will have @isConj@ to be @False@.
newCopyVector' :: (ReadVector x e m, ReadVector y e m) => x n e -> m (y n e)
newCopyVector' x | not (isConj x) = newCopyVector x
                 | otherwise = do
                     y <- newCopyVector (conj x)
                     withVectorPtr y $ \pY ->
                        BLAS.vconj (dim x) pY 1
                     return y
{-# INLINE newCopyVector' #-}

-- | @copyVector dst src@ replaces the values in @dst@ with those in
-- source.  The operands must be the same shape.
copyVector :: (WriteVector y e m, ReadVector x e m) =>
    y n e -> x n e -> m ()
copyVector y x = checkBinaryOp (shape x) (shape y) $ unsafeCopyVector y x
{-# INLINE copyVector #-}

unsafeCopyVector :: (ReadVector y e m, ReadVector x e m) =>
    y n e -> x n e -> m ()
unsafeCopyVector y x
    | isConj x =
        unsafeCopyVector (conj y) (conj x)
    | isConj y = do
        vectorCall2 BLAS.copy x y
        vectorCall  BLAS.vconj y
    | otherwise =
        vectorCall2 BLAS.copy x y
{-# INLINE unsafeCopyVector #-}

-- | Swap the values stored in two vectors.
swapVector :: (WriteVector y e m) => 
    y n e -> y n e -> m ()
swapVector x y = checkBinaryOp (shape x) (shape y) $ unsafeSwapVector x y
{-# INLINE swapVector #-}

unsafeSwapVector :: (WriteVector y e m) =>
    y n e -> y n e -> m ()
unsafeSwapVector x y
    | isConj x && isConj y =
        unsafeSwapVector (conj x) (conj y)
    | isConj x || isConj y =
        forM_ [0..(dim x - 1)] $ \i -> do
            tmp <- unsafeReadElem x i
            unsafeReadElem y i >>= unsafeWriteElem x i
            unsafeWriteElem y i tmp
    | otherwise =
        vectorCall2 BLAS.swap x y
{-# INLINE unsafeSwapVector #-}

-- | @subvectorView x o n@ creates a subvector view of @x@ starting at index @o@ 
-- and having length @n@.
subvectorView :: (BaseVector x e) => 
    x n e -> Int -> Int -> x n' e
subvectorView x = checkedSubvector (dim x) (unsafeSubvectorView x)
{-# INLINE subvectorView #-}

unsafeSubvectorView :: (BaseVector x e) => 
    x n e -> Int -> Int -> x n' e
unsafeSubvectorView = unsafeSubvectorViewWithStride 1
{-# INLINE unsafeSubvectorView #-}

-- | @subvectorViewWithStride s x o n@ creates a subvector view of @x@ starting 
-- at index @o@, having length @n@ and stride @s@.
subvectorViewWithStride :: (BaseVector x e) => 
    Int -> x n e -> Int -> Int -> x n' e
subvectorViewWithStride s x = 
    checkedSubvectorWithStride s (dim x) (unsafeSubvectorViewWithStride s x)
{-# INLINE subvectorViewWithStride #-}

-- | Get a new vector with elements with the conjugates of the elements
-- of the given vector
getConjVector :: (ReadVector x e m, ReadVector y e m) =>
    x n e -> m (y n e)
getConjVector = getUnaryOp unsafeDoConjVector
{-# INLINE getConjVector #-}

-- | Conjugate every element of the vector.
doConjVector :: (WriteVector y e m) => y n e -> m ()
doConjVector = unsafeDoConjVector
{-# INLINE doConjVector #-}

unsafeDoConjVector :: (ReadVector x e m) => x n e -> m ()
unsafeDoConjVector x =
    withVectorPtr x $ \_ ->
        doConjIOVector (unsafeVectorToIOVector x)
{-# INLINE unsafeDoConjVector #-}

-- | Get a new vector by scaling the elements of another vector
-- by a given value.
getScaledVector :: (ReadVector x e m, ReadVector y e m) =>
    e -> x n e -> m (y n e)
getScaledVector e = getUnaryOp (unsafeScaleByVector e)
{-# INLINE getScaledVector #-}

-- | Scale every element by the given value.
scaleByVector :: (WriteVector y e m) => e -> y n e -> m ()
scaleByVector = unsafeScaleByVector
{-# INLINE scaleByVector #-}

unsafeScaleByVector :: (ReadVector x e m) => e -> x n e -> m ()
unsafeScaleByVector k x =
    withVectorPtr x $ \_ ->
        scaleByIOVector k (unsafeVectorToIOVector x)
{-# INLINE unsafeScaleByVector #-}
                    
-- | Get a new vector by shifting the elements of another vector
-- by a given value.
getShiftedVector :: (ReadVector x e m, ReadVector y e m) =>
    e -> x n e -> m (y n e)
getShiftedVector e = getUnaryOp (unsafeShiftByVector e)
{-# INLINE getShiftedVector #-}

-- | Add the given value to every element.
shiftByVector :: (WriteVector y e m) => e -> y n e -> m ()
shiftByVector = unsafeShiftByVector
{-# INLINE shiftByVector #-}

unsafeShiftByVector :: (ReadVector x e m) => e -> x n e -> m ()
unsafeShiftByVector k x =
    withVectorPtr x $ \_ ->
        shiftByIOVector k (unsafeVectorToIOVector x)
{-# INLINE unsafeShiftByVector #-}

-- | @getAddVector x y@ creates a new vector equal to the sum @x+y@.  The 
-- operands must have the same dimension.
getAddVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
getAddVector = checkTensorOp2 unsafeGetAddVector
{-# INLINE getAddVector #-}

unsafeGetAddVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
unsafeGetAddVector = unsafeGetBinaryOp unsafeAddVector
{-# INLINE unsafeGetAddVector #-}

-- | @addVector y x@ replaces @y@ with @y+x@.
addVector :: (WriteVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
addVector y x = checkBinaryOp (dim y) (dim x) $ unsafeAddVector y x
{-# INLINE addVector #-}

unsafeAddVector :: (ReadVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
unsafeAddVector y x = unsafeAxpyVector 1 x y
{-# INLINE unsafeAddVector #-}

-- | @getSubVector x y@ creates a new tensor equal to the difference @x-y@.  
-- The operands must have the same dimension.
getSubVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
getSubVector = checkTensorOp2 unsafeGetSubVector
{-# INLINE getSubVector #-}

unsafeGetSubVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
unsafeGetSubVector = unsafeGetBinaryOp unsafeSubVector
{-# INLINE unsafeGetSubVector #-}

-- | @subVector y x@ replaces @y@ with @y-x@.
subVector :: (WriteVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
subVector y x = checkBinaryOp (dim y) (dim x) $ unsafeSubVector y x
{-# INLINE subVector #-}

unsafeSubVector :: (ReadVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
unsafeSubVector y x = unsafeAxpyVector (-1) x y
{-# INLINE unsafeSubVector #-}

-- | @axpyVector alpha x y@ replaces @y@ with @alpha * x + y@.
axpyVector :: (ReadVector x e m, WriteVector y e m) =>
    e -> x n e -> y n e -> m ()
axpyVector alpha x y = 
    checkBinaryOp (shape x) (shape y) $ unsafeAxpyVector alpha x y
{-# INLINE axpyVector #-}

unsafeAxpyVector :: (ReadVector x e m, ReadVector y e m) =>
    e -> x n e -> y n e -> m ()
unsafeAxpyVector alpha x y
    | isConj y =
        unsafeAxpyVector (conjugate alpha) (conj x) (conj y)
    | isConj x =
        vectorCall2 (flip BLAS.acxpy alpha) x y
    | otherwise =
        vectorCall2 (flip BLAS.axpy alpha) x y
{-# INLINE unsafeAxpyVector #-}

-- | @getMulVector x y@ creates a new vector equal to the elementwise product 
-- @x*y@.  The operands must have the same dimensino
getMulVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
getMulVector = checkTensorOp2 unsafeGetMulVector
{-# INLINE getMulVector #-}

unsafeGetMulVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
unsafeGetMulVector = unsafeGetBinaryOp unsafeMulVector
{-# INLINE unsafeGetMulVector #-}

-- | @mulVector y x@ replaces @y@ with @y*x@.
mulVector :: (WriteVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
mulVector y x =
    checkBinaryOp (shape y) (shape x) $ unsafeMulVector y x
{-# INLINE mulVector #-}
 
unsafeMulVector :: (ReadVector y e m, ReadVector x e m) =>
    y n e -> x n e -> m ()
unsafeMulVector y x
    | isConj y =
        unsafeMulVector (conj y) (conj x)
    | isConj x =
        vectorCall2 BLAS.vcmul x y
    | otherwise =
        vectorCall2 BLAS.vmul x y
{-# INLINE unsafeMulVector #-}

-- | @getDivVector x y@ creates a new vector equal to the elementwise 
-- ratio @x/y@.  The operands must have the same shape.
getDivVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
getDivVector = checkTensorOp2 unsafeGetDivVector
{-# INLINE getDivVector #-}

unsafeGetDivVector :: 
    (ReadVector x e m, ReadVector y e m, ReadVector z e m) => 
    x n e -> y n e -> m (z n e)
unsafeGetDivVector = unsafeGetBinaryOp unsafeDivVector
{-# INLINE unsafeGetDivVector #-}

-- | @divVector y x@ replaces @y@ with @y/x@.
divVector :: (WriteVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
divVector y x =
    checkBinaryOp (shape y) (shape x) $ unsafeDivVector y x
{-# INLINE divVector #-}

unsafeDivVector :: (ReadVector y e m, ReadVector x e m) => 
    y n e -> x n e -> m ()
unsafeDivVector y x
    | isConj y =
        unsafeDivVector (conj y) (conj x)
    | isConj x =
        vectorCall2 BLAS.vcdiv x y
    | otherwise =
        vectorCall2 BLAS.vdiv x y
{-# INLINE unsafeDivVector #-}

-- | Gets the sum of the absolute values of the vector entries.
getSumAbs :: (ReadVector x e m) => x n e -> m Double
getSumAbs = vectorCall BLAS.asum
{-# INLINE getSumAbs #-}
    
-- | Gets the 2-norm of a vector.
getNorm2 :: (ReadVector x e m) => x n e -> m Double
getNorm2 = vectorCall BLAS.nrm2
{-# INLINE getNorm2 #-}

-- | Gets the index and norm of the element with maximum magnitude.  This is 
-- undefined if any of the elements are @NaN@.  It will throw an exception if 
-- the dimension of the vector is 0.
getWhichMaxAbs :: (ReadVector x e m) => x n e -> m (Int, e)
getWhichMaxAbs x =
    case (dim x) of
        0 -> fail $ "getWhichMaxAbs of an empty vector"
        _ -> do
            i <- vectorCall BLAS.iamax x
            e <- unsafeReadElem x i
            return (i,e)
{-# INLINE getWhichMaxAbs #-}

-- | Computes the dot product of two vectors.
getDot :: (ReadVector x e m, ReadVector y e m) => 
    x n e -> y n e -> m e
getDot x y = checkVecVecOp "getDot" (dim x) (dim y) $ unsafeGetDot x y
{-# INLINE getDot #-}

unsafeGetDot :: (ReadVector x e m, ReadVector y e m) => 
    x n e -> y n e -> m e
unsafeGetDot x y =
    case (isConj x, isConj y) of
        (False, False) -> vectorCall2 BLAS.dotc x y
        (True , False) -> vectorCall2 BLAS.dotu x y
        (False, True ) -> liftM conjugate $ vectorCall2 BLAS.dotu x y
        (True , True)  -> liftM conjugate $ vectorCall2 BLAS.dotc x y
{-# INLINE unsafeGetDot #-}

instance (Elem e) => BaseVector IOVector e where
    dim = dimIOVector
    {-# INLINE dim #-}
    stride = strideIOVector
    {-# INLINE stride #-}
    isConj = isConjIOVector
    {-# INLINE isConj #-}
    conj = conjIOVector
    {-# INLINE conj #-}
    unsafeSubvectorViewWithStride = unsafeSubvectorViewWithStrideIOVector
    {-# INLINE unsafeSubvectorViewWithStride #-}
    unsafeIOVectorToVector = id
    {-# INLINE unsafeIOVectorToVector #-}
    unsafeVectorToIOVector = id
    {-# INLINE unsafeVectorToIOVector #-}
    withVectorPtrIO = withIOVectorPtr
    {-# INLINE withVectorPtrIO #-}
    
instance (BLAS1 e) => ReadVector IOVector e IO where
    newVector_ = newIOVector_
    {-# INLINE newVector_ #-}
    withVectorPtr = withIOVectorPtr
    {-# INLINE withVectorPtr #-}
    freezeVector = freezeIOVector
    {-# INLINE freezeVector #-}
    unsafeFreezeVector = unsafeFreezeIOVector
    {-# INLINE unsafeFreezeVector #-}
    thawVector = thawIOVector
    {-# INLINE thawVector #-}
    unsafeThawVector = unsafeThawIOVector
    {-# INLINE unsafeThawVector #-}

instance (BLAS1 e) => WriteVector IOVector e IO where

-- | Create a vector with the given dimension and elements.  The elements
-- given in the association list must all have unique indices, otherwise
-- the result is undefined.
vector :: (BLAS1 e) => Int -> [(Int, e)] -> Vector n e
vector n ies = unsafePerformIO $
    unsafeFreezeIOVector =<< newVector n ies
{-# NOINLINE vector #-}

-- | Same as 'vector', but does not range-check the indices.
unsafeVector :: (BLAS1 e) => Int -> [(Int, e)] -> Vector n e
unsafeVector n ies = unsafePerformIO $
    unsafeFreezeIOVector =<< unsafeNewVector n ies
{-# NOINLINE unsafeVector #-}

-- | Create a vector of the given dimension with elements initialized
-- to the values from the list.  @listVector n es@ is equivalent to 
-- @vector n (zip [0..(n-1)] es)@, except that the result is undefined 
-- if @length es@ is less than @n@.
listVector :: (BLAS1 e) => Int -> [e] -> Vector n e
listVector n es = Vector $ unsafePerformIO $ newListVector n es
{-# NOINLINE listVector #-}

replaceVector :: (BLAS1 e) => Vector n e -> [(Int,e)] -> Vector n e
replaceVector (Vector x) ies =
    unsafePerformIO $ do
        y <- newCopyVector x
        mapM_ (uncurry $ writeElem y) ies
        return (Vector y)
{-# NOINLINE replaceVector #-}

unsafeReplaceVector :: (BLAS1 e) => Vector n e -> [(Int,e)] -> Vector n e
unsafeReplaceVector (Vector x) ies =
    unsafePerformIO $ do
        y <- newCopyVector x
        mapM_ (uncurry $ unsafeWriteElem y) ies
        return (Vector y)
{-# NOINLINE unsafeReplaceVector #-}

-- | @zeroVector n@ creates a vector of dimension @n@ with all values
-- set to zero.
zeroVector :: (BLAS1 e) => Int -> Vector n e
zeroVector n = unsafePerformIO $ 
    unsafeFreezeIOVector =<< newZeroVector n
{-# NOINLINE zeroVector #-}

-- | @constantVector n e@ creates a vector of dimension @n@ with all values
-- set to @e@.
constantVector :: (BLAS1 e) => Int -> e -> Vector n e
constantVector n e = unsafePerformIO $
    unsafeFreezeIOVector =<< newConstantVector n e
{-# NOINLINE constantVector #-}

-- | @basisVector n i@ creates a vector of dimension @n@ with zeros 
-- everywhere but position @i@, where there is a one.
basisVector :: (BLAS1 e) => Int -> Int -> Vector n e
basisVector n i = unsafePerformIO $
    unsafeFreezeIOVector =<< newBasisVector n i
{-# NOINLINE basisVector #-}

-- | @subvector x o n@ creates a subvector of @x@ starting at index @o@ 
-- and having length @n@.
subvector :: (BLAS1 e) => Vector n e -> Int -> Int -> Vector n' e
subvector = subvectorView
{-# INLINE subvector #-}

unsafeSubvector :: (BLAS1 e) => Vector n e -> Int -> Int -> Vector n' e
unsafeSubvector = unsafeSubvectorView
{-# INLINE unsafeSubvector #-}

-- | @subvectorWithStride s x o n@ creates a subvector of @x@ starting 
-- at index @o@, having length @n@ and stride @s@.
subvectorWithStride :: (BLAS1 e) =>
    Int -> Vector n e -> Int -> Int -> Vector n' e
subvectorWithStride = subvectorViewWithStride
{-# INLINE subvectorWithStride #-}
    
sizeVector :: Vector n e -> Int
sizeVector (Vector x) = sizeIOVector x
{-# INLINE sizeVector #-}

indicesVector :: Vector n e -> [Int]
indicesVector (Vector x) = indicesIOVector x
{-# INLINE indicesVector #-}

elemsVector :: (Elem e) => Vector n e -> [e]
elemsVector x | isConj x  = (map conjugate . elemsVector . conj) x
              | otherwise = case x of { (Vector (IOVector f p n incX _)) ->
    let end = p `advancePtr` (n*incX)
        go p' | p' == end = inlinePerformIO $ do
                                io <- touchForeignPtr f
                                io `seq` return []
              | otherwise = let e = inlinePerformIO (peek p')
                                es = go (p' `advancePtr` incX)
                            in e `seq` (e:es)
    in go p }
{-# SPECIALIZE INLINE elemsVector :: Vector n Double -> [Double] #-}
{-# SPECIALIZE INLINE elemsVector :: Vector n (Complex Double) -> [Complex Double] #-}

assocsVector :: (Elem e) => Vector n e -> [(Int,e)]
assocsVector x = zip (indicesVector x) (elemsVector x)
{-# INLINE assocsVector #-}

unsafeAtVector :: (Elem e) => Vector n e -> Int -> e
unsafeAtVector (Vector x) i = inlinePerformIO (unsafeReadElemIOVector x i)
{-# INLINE unsafeAtVector #-}

tmapVector :: (BLAS1 e) => (e -> e) -> Vector n e -> Vector n e
tmapVector f x = listVector (dim x) (map f $ elemsVector x)
{-# INLINE tmapVector #-}

tzipWithVector :: (BLAS1 e) =>
    (e -> e -> e) -> Vector n e -> Vector n e -> Vector n e
tzipWithVector f x y
    | dim y /= n =
        error ("tzipWith: vector lengths differ; first has length `" ++
                show n ++ "' and second has length `" ++
                show (dim y) ++ "'")
    | otherwise =
        listVector n (zipWith f (elems x) (elems y))
  where
    n = dim x
{-# INLINE tzipWithVector #-}

scaleVector :: (BLAS1 e) => e -> Vector n e -> Vector n e
scaleVector e (Vector x) = 
    unsafePerformIO $ unsafeFreezeIOVector =<< getScaledVector e x
{-# NOINLINE scaleVector #-}

shiftVector :: (BLAS1 e) => e -> Vector n e -> Vector n e
shiftVector e (Vector x) = 
    unsafePerformIO $ unsafeFreezeIOVector =<< getShiftedVector e x
{-# NOINLINE shiftVector #-}

-- | Compute the sum of absolute values of entries in the vector.
sumAbs :: (BLAS1 e) => Vector n e -> Double
sumAbs (Vector x) = unsafePerformIO $ getSumAbs x
{-# NOINLINE sumAbs #-}

-- | Compute the 2-norm of a vector.
norm2 :: (BLAS1 e) => Vector n e -> Double
norm2 (Vector x) = unsafePerformIO $ getNorm2 x
{-# NOINLINE norm2 #-}

-- | Get the index and norm of the element with absulte value.  Not valid 
-- if any of the vector entries are @NaN@.  Raises an exception if the 
-- vector has length @0@.
whichMaxAbs :: (BLAS1 e) => Vector n e -> (Int, e)
whichMaxAbs (Vector x) = unsafePerformIO $ getWhichMaxAbs x
{-# NOINLINE whichMaxAbs #-}

-- | Compute the dot product of two vectors.
(<.>) :: (BLAS1 e) => Vector n e -> Vector n e -> e
(<.>) x y = unsafePerformIO $ getDot x y
{-# NOINLINE (<.>) #-}

instance Shaped Vector Int e where
    shape (Vector x) = shapeIOVector x
    {-# INLINE shape #-}
    bounds (Vector x) = boundsIOVector x
    {-# INLINE bounds #-}

instance (BLAS1 e) => ITensor Vector Int e where
    (//) = replaceVector
    {-# INLINE (//) #-}
    unsafeReplace = unsafeReplaceVector
    {-# INLINE unsafeReplace #-}
    unsafeAt = unsafeAtVector
    {-# INLINE unsafeAt #-}
    size = sizeVector
    {-# INLINE size #-}
    elems = elemsVector
    {-# INLINE elems #-}
    indices = indicesVector
    {-# INLINE indices #-}
    assocs = assocsVector
    {-# INLINE assocs #-}
    tmap = tmapVector
    {-# INLINE tmap #-}
    (*>) = scaleVector
    {-# INLINE (*>) #-}
    shift = shiftVector
    {-# INLINE shift #-}

instance (BLAS1 e, Monad m) => ReadTensor Vector Int e m where
    getSize = return . size
    {-# INLINE getSize #-}
    getAssocs = return . assocs
    {-# INLINE getAssocs #-}
    getIndices = return . indices
    {-# INLINE getIndices #-}
    getElems = return . elems
    {-# INLINE getElems #-}
    getAssocs' = return . assocs
    {-# INLINE getAssocs' #-}
    getIndices' = return . indices
    {-# INLINE getIndices' #-}
    getElems' = return . elems
    {-# INLINE getElems' #-}
    unsafeReadElem x i = return $ unsafeAt x i
    {-# INLINE unsafeReadElem #-}
    
instance (Elem e) => BaseVector Vector e where    
    dim (Vector x) = dimIOVector x
    {-# INLINE dim #-}
    stride (Vector x) = strideIOVector x
    {-# INLINE stride #-}
    isConj (Vector x) = isConjIOVector x
    {-# INLINE isConj #-}
    conj (Vector x) = (Vector (conjIOVector x))
    {-# INLINE conj #-}
    unsafeSubvectorViewWithStride s (Vector x) o n = 
        Vector (unsafeSubvectorViewWithStrideIOVector s x o n)
    {-# INLINE unsafeSubvectorViewWithStride #-}
    unsafeIOVectorToVector = Vector
    {-# INLINE unsafeIOVectorToVector #-}
    unsafeVectorToIOVector (Vector x) = x
    {-# INLINE unsafeVectorToIOVector #-}
    withVectorPtrIO (Vector x) = withIOVectorPtr x
    {-# INLINE withVectorPtrIO #-}

instance (BLAS1 e) => ReadVector Vector e IO where
    newVector_ n = liftM Vector $ newIOVector_ n
    {-# INLINE newVector_ #-}
    withVectorPtr (Vector x) f = withVectorPtr x f
    {-# INLINE withVectorPtr #-}
    freezeVector (Vector x) = freezeIOVector x
    {-# INLINE freezeVector #-}
    unsafeFreezeVector = return
    {-# INLINE unsafeFreezeVector #-}
    thawVector = liftM Vector . thawIOVector
    {-# INLINE thawVector #-}
    unsafeThawVector = return
    {-# INLINE unsafeThawVector #-}

instance (BLAS1 e) => ReadVector Vector e (ST s) where
    newVector_ n = unsafeIOToST $ liftM Vector $ newIOVector_ n
    {-# INLINE newVector_ #-}
    withVectorPtr (Vector x) f = unsafeIOToST $ withVectorPtr x f
    {-# INLINE withVectorPtr #-}
    freezeVector (Vector x) = unsafeIOToST $ freezeIOVector x
    {-# INLINE freezeVector #-}
    unsafeFreezeVector = return
    {-# INLINE unsafeFreezeVector #-}
    thawVector = unsafeIOToST . liftM Vector . thawIOVector
    {-# INLINE thawVector #-}
    unsafeThawVector = return
    {-# INLINE unsafeThawVector #-}

instance (Elem e, Show e) => Show (Vector n e) where
    show x
        | isConj x  = "conj (" ++ show (conj x) ++ ")"
        | otherwise = "listVector " ++ show (dim x) ++ " " ++ show (elemsVector x)

instance (BLAS1 e) => Eq (Vector n e) where
    (==) = compareVectorWith (==)

instance (BLAS1 e) => AEq (Vector n e) where
    (===) = compareVectorWith (===)
    (~==) = compareVectorWith (~==)

compareVectorWith :: (Elem e) => 
    (e -> e -> Bool) -> 
        Vector n e -> Vector n e -> Bool
compareVectorWith cmp x y
    | isConj x && isConj y =
        compareVectorWith cmp (conj x) (conj y)
    | otherwise =
        (dim x == dim y) && (and $ zipWith cmp (elemsVector x) (elemsVector y))

instance (BLAS1 e) => Num (Vector n e) where
    (+) x y = unsafePerformIO $ unsafeFreezeIOVector =<< getAddVector x y
    {-# NOINLINE (+) #-}
    (-) x y = unsafePerformIO $ unsafeFreezeIOVector =<< getSubVector x y
    {-# NOINLINE (-) #-}
    (*) x y = unsafePerformIO $ unsafeFreezeIOVector =<< getMulVector x y
    {-# NOINLINE (*) #-}
    negate = ((-1) *>)
    {-# INLINE negate #-}
    abs           = tmap abs
    signum        = tmap signum
    fromInteger n = listVector 1 [fromInteger n]
    
instance (BLAS1 e) => Fractional (Vector n e) where
    (/) x y      = unsafePerformIO $ unsafeFreezeIOVector =<< getDivVector x y
    {-# NOINLINE (/) #-}
    recip          = tmap recip
    fromRational q = listVector 1 [fromRational q]
    
instance (BLAS1 e, Floating e) => Floating (Vector n e) where
    pi    = listVector 1 [pi]
    exp   = tmap exp
    sqrt  = tmap sqrt
    log   = tmap log
    (**)  = tzipWithVector (**)
    sin   = tmap sin
    cos   = tmap cos
    tan   = tmap tan
    asin  = tmap asin
    acos  = tmap acos
    atan  = tmap atan
    sinh  = tmap sinh
    cosh  = tmap cosh
    tanh  = tmap tanh
    asinh = tmap asinh
    acosh = tmap acosh
    atanh = tmap atanh

vectorCall :: (ReadVector x e m) => 
    (Int -> Ptr e -> Int -> IO a) 
        ->  x n e -> m a
vectorCall f x =
    let n    = dim x
        incX = stride x
    in withVectorPtr x $ \pX -> 
           f n pX incX
{-# INLINE vectorCall #-}

vectorCall2 :: (ReadVector x e m, ReadVector y f m) => 
       (Int -> Ptr e -> Int -> Ptr f -> Int -> IO a) 
    -> x n e -> y n' f -> m a
vectorCall2 f x y =
    let n    = dim x
        incX = stride x
        incY = stride y
    in withVectorPtr x $ \pX ->
       withVectorPtrIO y $ \pY ->
           f n pX incX pY incY
{-# INLINE vectorCall2 #-}    

checkTensorOp2 :: (Shaped x i e, Shaped y i e) => 
    (x n e -> y n e -> a) ->
        x n e -> y n e -> a
checkTensorOp2 f x y = 
    checkBinaryOp (shape x) (shape y) $ f x y
{-# INLINE checkTensorOp2 #-}

getUnaryOp :: (ReadVector x e m, ReadVector y e m) =>
    (y n e -> m ()) -> x n e -> m (y n e)
getUnaryOp f x = do
    y <- newCopyVector x
    f y
    return y
{-# INLINE getUnaryOp #-}

unsafeGetBinaryOp :: 
    (ReadVector z e m, ReadVector x e m, ReadVector y e m) => 
    (z n e -> y n e -> m ()) ->
        x n e -> y n e -> m (z n e)
unsafeGetBinaryOp f x y = do
    z <- newCopyVector x
    f z y
    return z
{-# INLINE unsafeGetBinaryOp #-}