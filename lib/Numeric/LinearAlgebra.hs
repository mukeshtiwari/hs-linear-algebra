-----------------------------------------------------------------------------
-- |
-- Module     : Numeric.LinearAlgebra
-- Copyright  : Copyright (c) 2010, Patrick Perry <patperry@gmail.com>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@gmail.com>
-- Stability  : experimental
--
-- Linear algebra types and operations
--

module Numeric.LinearAlgebra (
    module Numeric.LinearAlgebra.Types,
    module Numeric.LinearAlgebra.Vector,
    module Numeric.LinearAlgebra.Vector.ST,
    module Numeric.LinearAlgebra.Matrix,
    module Numeric.LinearAlgebra.Matrix.ST,
    module Numeric.LinearAlgebra.Matrix.Herm,
    module Numeric.LinearAlgebra.Factor.Cholesky,
    ) where

import Numeric.LinearAlgebra.Types
import Numeric.LinearAlgebra.Vector
import Numeric.LinearAlgebra.Vector.ST hiding ( dimVector, indicesVector,
    sliceVector, splitVectorAt, dropVector, takeVector )
import Numeric.LinearAlgebra.Matrix
import Numeric.LinearAlgebra.Matrix.ST hiding ( dimMatrix, indicesMatrix,
    colMatrix, colsMatrix, sliceMatrix, splitRowsMatrixAt, 
    splitColsMatrixAt )
import Numeric.LinearAlgebra.Matrix.Herm
import Numeric.LinearAlgebra.Factor.Cholesky
