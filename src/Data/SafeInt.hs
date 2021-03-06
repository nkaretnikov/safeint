-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SafeInt
-- Copyright   :  (c) 2010 Well-Typed LLP
-- License     :  BSD3
--
-- Maintainer  :  Andres Loeh <andres@well-typed.com>
-- Stability   :  experimental
-- Portability :  non-portable (GHC Extensions)
--
-- Defines a variant of Haskell's Int type that is overflow-checked. If
-- an overflow or arithmetic error occurs, a run-time exception is thrown.
--
--------------------------------------------------------------------------

{-# LANGUAGE MagicHash, UnboxedTuples, BangPatterns #-}

module Data.SafeInt (SafeInt(..), fromSafe, toSafe) where

import GHC.Prim
import GHC.Base
import GHC.Err
import GHC.Num
import GHC.Word
import GHC.Real
import GHC.Types

newtype SafeInt = SI Int

fromSafe :: SafeInt -> Int
fromSafe (SI x) = x

toSafe :: Int -> SafeInt
toSafe x = SI x

instance Show SafeInt where

  showsPrec p x = showsPrec p (fromSafe x)

instance Read SafeInt where

  readsPrec p xs = [ (toSafe x, r) | (x, r) <- readsPrec p xs ]

instance Eq SafeInt where

  SI x == SI y = eqInt x y
  SI x /= SI y = neInt x y

instance Ord SafeInt where

  SI x <  SI y = ltInt x y
  SI x <= SI y = leInt x y
  SI x >  SI y = gtInt x y
  SI x >= SI y = geInt x y

-- | In the `Num' instance, we plug in our own addition, multiplication
-- and subtraction function that perform overflow-checking.
instance Num SafeInt where

  (+)               = plusSI
  (*)               = timesSI
  (-)               = minusSI
  negate (SI y)
    | y == minInt   = overflowError
    | otherwise     = SI (negate y)
  abs x
    | x >= 0        = x
    | otherwise     = negate x
  signum x | x > 0  = 1
  signum 0          = 0
  signum _          = -1
  fromInteger x
    | x > maxBoundInteger || x < minBoundInteger
                    = overflowError
    | otherwise     = SI (fromInteger x)

maxBoundInteger :: Integer
maxBoundInteger = toInteger maxInt

minBoundInteger :: Integer
minBoundInteger = toInteger minInt

instance Bounded SafeInt where

  minBound = SI minInt
  maxBound = SI maxInt

instance Enum SafeInt where

  succ (SI x) = SI (succ x)
  pred (SI x) = SI (pred x)
  toEnum                = SI
  fromEnum              = fromSafe

  {-# INLINE enumFrom #-}
  enumFrom (SI (I# x)) = eftInt x maxInt#
      where !(I# maxInt#) = maxInt

  {-# INLINE enumFromTo #-}
  enumFromTo (SI (I# x)) (SI (I# y)) = eftInt x y

  {-# INLINE enumFromThen #-}
  enumFromThen (SI (I# x1)) (SI (I# x2)) = efdInt x1 x2

  {-# INLINE enumFromThenTo #-}
  enumFromThenTo (SI (I# x1)) (SI (I# x2)) (SI (I# y)) = efdtInt x1 x2 y

-- The following code is copied/adapted from GHC.Enum.

{-# RULES
"eftInt"        [~1] forall x y. eftInt x y = build (\ c n -> eftIntFB c n x y)
"eftIntList"    [1] eftIntFB  (:) [] = eftInt
 #-}

eftInt :: Int# -> Int# -> [SafeInt]
-- [x1..x2]
eftInt x0 y | x0 ># y    = []
            | otherwise = go x0
               where
                 go x = SI (I# x) : if x ==# y then [] else go (x +# 1#)

{-# INLINE [0] eftIntFB #-}
eftIntFB :: (SafeInt -> r -> r) -> r -> Int# -> Int# -> r
eftIntFB c n x0 y | x0 ># y    = n
                  | otherwise = go x0
                 where
                   go x = SI (I# x) `c` if x ==# y then n else go (x +# 1#)
                        -- Watch out for y=maxBound; hence ==, not >
        -- Be very careful not to have more than one "c"
        -- so that when eftInfFB is inlined we can inline
        -- whatever is bound to "c"

{-# RULES
"efdtInt"       [~1] forall x1 x2 y.
                     efdtInt x1 x2 y = build (\ c n -> efdtIntFB c n x1 x2 y)
"efdtIntUpList" [1]  efdtIntFB (:) [] = efdtInt
 #-}

efdInt :: Int# -> Int# -> [SafeInt]
-- [x1,x2..maxInt]
efdInt x1 x2
 | x2 >=# x1 = case maxInt of I# y -> efdtIntUp x1 x2 y
 | otherwise = case minInt of I# y -> efdtIntDn x1 x2 y

efdtInt :: Int# -> Int# -> Int# -> [SafeInt]
-- [x1,x2..y]
efdtInt x1 x2 y
 | x2 >=# x1 = efdtIntUp x1 x2 y
 | otherwise = efdtIntDn x1 x2 y

{-# INLINE [0] efdtIntFB #-}
efdtIntFB :: (SafeInt -> r -> r) -> r -> Int# -> Int# -> Int# -> r
efdtIntFB c n x1 x2 y
 | x2 >=# x1  = efdtIntUpFB c n x1 x2 y
 | otherwise  = efdtIntDnFB c n x1 x2 y

-- Requires x2 >= x1
efdtIntUp :: Int# -> Int# -> Int# -> [SafeInt]
efdtIntUp x1 x2 y    -- Be careful about overflow!
 | y <# x2   = if y <# x1 then [] else [SI (I# x1)]
 | otherwise = -- Common case: x1 <= x2 <= y
               let !delta = x2 -# x1 -- >= 0
                   !y' = y -# delta  -- x1 <= y' <= y; hence y' is representable

                   -- Invariant: x <= y
                   -- Note that: z <= y' => z + delta won't overflow
                   -- so we are guaranteed not to overflow if/when we recurse
                   go_up x | x ># y'  = [SI (I# x)]
                           | otherwise = SI (I# x) : go_up (x +# delta)
               in SI (I# x1) : go_up x2

-- Requires x2 >= x1
efdtIntUpFB :: (SafeInt -> r -> r) -> r -> Int# -> Int# -> Int# -> r
efdtIntUpFB c n x1 x2 y    -- Be careful about overflow!
 | y <# x2   = if y <# x1 then n else SI (I# x1) `c` n
 | otherwise = -- Common case: x1 <= x2 <= y
               let !delta = x2 -# x1 -- >= 0
                   !y' = y -# delta  -- x1 <= y' <= y; hence y' is representable

                   -- Invariant: x <= y
                   -- Note that: z <= y' => z + delta won't overflow
                   -- so we are guaranteed not to overflow if/when we recurse
                   go_up x | x ># y'   = SI (I# x) `c` n
                           | otherwise = SI (I# x) `c` go_up (x +# delta)
               in SI (I# x1) `c` go_up x2

-- Requires x2 <= x1
efdtIntDn :: Int# -> Int# -> Int# -> [SafeInt]
efdtIntDn x1 x2 y    -- Be careful about underflow!
 | y ># x2   = if y ># x1 then [] else [SI (I# x1)]
 | otherwise = -- Common case: x1 >= x2 >= y
               let !delta = x2 -# x1 -- <= 0
                   !y' = y -# delta  -- y <= y' <= x1; hence y' is representable

                   -- Invariant: x >= y
                   -- Note that: z >= y' => z + delta won't underflow
                   -- so we are guaranteed not to underflow if/when we recurse
                   go_dn x | x <# y'  = [SI (I# x)]
                           | otherwise = SI (I# x) : go_dn (x +# delta)
   in SI (I# x1) : go_dn x2


-- Requires x2 <= x1
efdtIntDnFB :: (SafeInt -> r -> r) -> r -> Int# -> Int# -> Int# -> r
efdtIntDnFB c n x1 x2 y    -- Be careful about underflow!
 | y ># x2 = if y ># x1 then n else SI (I# x1) `c` n
 | otherwise = -- Common case: x1 >= x2 >= y
               let !delta = x2 -# x1 -- <= 0
                   !y' = y -# delta  -- y <= y' <= x1; hence y' is representable

                   -- Invariant: x >= y
                   -- Note that: z >= y' => z + delta won't underflow
                   -- so we are guaranteed not to underflow if/when we recurse
                   go_dn x | x <# y'   = SI (I# x) `c` n
                           | otherwise = SI (I# x) `c` go_dn (x +# delta)
               in SI (I# x1) `c` go_dn x2

-- The following code is copied/adapted from GHC.Real.

instance Real SafeInt where

  toRational (SI x) = toInteger x % 1

instance Integral SafeInt where

    toInteger (SI (I# i)) = smallInteger i

    SI a `quot` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  = SI (a `quotInt` b)

    SI a `rem` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  = SI (a `remInt` b)

    SI a `div` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  = SI (a `divInt` b)

    SI a `mod` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  = SI (a `modInt` b)

    SI a `quotRem` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  =  a `quotRemSafeInt` b

    SI a `divMod` SI b
     | b == 0                     = divZeroError
     | a == minBound && b == (-1) = overflowError
     | otherwise                  =  a `divModSafeInt` b

quotRemSafeInt :: Int -> Int -> (SafeInt, SafeInt)
quotRemSafeInt a@(I# _) b@(I# _) = (SI (a `quotInt` b), SI (a `remInt` b))

divModSafeInt ::  Int -> Int -> (SafeInt, SafeInt)
divModSafeInt x@(I# _) y@(I# _) = (SI (x `divInt` y), SI (x `modInt` y))

plusSI :: SafeInt -> SafeInt -> SafeInt
plusSI (SI (I# x#)) (SI (I# y#)) =
  case addIntC# x# y# of
    (# r#, 0# #) -> SI (I# r#)
    (# _ , _  #) -> overflowError

minusSI :: SafeInt -> SafeInt -> SafeInt
minusSI (SI (I# x#)) (SI (I# y#)) =
  case subIntC# x# y# of
    (# r#, 0# #) -> SI (I# r#)
    (# _ , _  #) -> overflowError

timesSI :: SafeInt -> SafeInt -> SafeInt
timesSI (SI (I# x#)) (SI (I# y#)) =
  case mulIntMayOflo# x# y# of
    0# -> SI (I# (x# *# y#))
    _  -> overflowError

{-# RULES
"fromIntegral/Int->SafeInt"     fromIntegral = toSafe
"fromIntegral/SafeInt->SafeInt" fromIntegral = id :: SafeInt -> SafeInt
  #-}

-- Specialized versions of several functions. They're specialized for
-- Int in the GHC base libraries. We try to get the same effect by
-- including specialized code and adding a rewrite rule.

sumS :: [SafeInt] -> SafeInt
sumS     l       = sum' l 0
  where
    sum' []     a = a
    sum' (x:xs) a = sum' xs (a + x)

productS :: [SafeInt] -> SafeInt
productS l       = prod l 1
  where
    prod []     a = a
    prod (x:xs) a = prod xs (a*x)

{-# RULES
  "sum/SafeInt"          sum = sumS;
  "product/SafeInt"      product = productS
  #-}

{-# RULES
  "sum/SafeInt"          sum = sumS;
  "product/SafeInt"      product = productS
  #-}

lcmS :: SafeInt -> SafeInt -> SafeInt
lcmS _      (SI 0)  =  SI 0
lcmS (SI 0) _       =  SI 0
lcmS (SI x) (SI y)  =  abs (SI (x `quot` (gcd x y)) * SI y)

{-# RULES
  "lcm/SafeInt"          lcm = lcmS;
  "gcd/SafeInt"          gcd = \ (SI a) (SI b) -> SI (gcd a b)
  #-}
