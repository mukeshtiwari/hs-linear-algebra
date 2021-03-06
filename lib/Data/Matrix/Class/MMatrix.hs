-----------------------------------------------------------------------------
-- |
-- Module     : Data.Matrix.Class.MMatrix
-- Copyright  : Copyright (c) , Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--
-- An overloaded interface for mutable matrices. The type class associates a
-- matrix with a monad type in which operations can be perfomred.  The
-- matrices provide access to rows and columns, and can operate via
-- multiplication on dense vectors and matrices.  
--

module Data.Matrix.Class.MMatrix (
    -- * The MMatrix type class
    MMatrix,

    -- * Getting rows and columns
    getRow,
    getCol,
    getRows,
    getCols,
    getRows',
    getCols',
    
    -- * Matrix and vector multiplication
    getApplyVector,
    getSApplyVector,
    
    getApplyMatrix,
    getSApplyMatrix,

    -- * In-place multiplication
    doApplyVector,
    doSApplyAddVector,
    doApplyVector_,
    doSApplyVector_,
    
    doApplyMatrix,
    doSApplyAddMatrix,
    doApplyMatrix_,
    doSApplyMatrix_,
    ) where

import Data.Matrix.Class.MMatrixBase

