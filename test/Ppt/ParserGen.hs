module Ppt.ParserGen where

import Test.QuickCheck
import System.Random
import Ppt.Frame.ParsedRep

instance Random ETimeRep where
  randomR (s, e) gen =
    let intify_t ETimeVal = 0
        intify_t (ETimeSpec s) = intify_tsrc s
        intify_tsrc ETimeClockRealtime = 1
        intify_tsrc ETimeClockRealtimeCoarse = 2
        intify_tsrc ETimeClockMonotonic = 3
        intify_tsrc ETimeClockMonotonicCoarse = 4
        intify_tsrc ETimeClockMonotonicRaw = 5
        intify_tsrc ETimeClockBoottime = 6
        intify_tsrc ETimeClockProcessCputimeId = 7
        intify_tsrc ETimeClockThreadCputimeId = 8
        primifysrc 1 = ETimeClockRealtime
        primifysrc 2 = ETimeClockRealtimeCoarse
        primifysrc 3 = ETimeClockMonotonic
        primifysrc 4 = ETimeClockMonotonicCoarse
        primifysrc 5 = ETimeClockMonotonicRaw
        primifysrc 6 = ETimeClockBoottime
        primifysrc 7 = ETimeClockProcessCputimeId
        primifysrc 8 = ETimeClockThreadCputimeId
        primify_t 0 = ETimeVal
        primify_t n = ETimeSpec $ primifysrc n
        start_v = intify_t s
        end_v = intify_t e
        start = min start_v end_v
        end = 1+ max start_v end_v
        (ival, gen') = next gen
        result = primify_t (start + (ival `mod` (end - start)))
    in (result, gen')
  random = randomR (ETimeVal, ETimeSpec ETimeClockThreadCputimeId)

instance Arbitrary ETimeRep where
  arbitrary = choose (ETimeVal, ETimeSpec ETimeClockThreadCputimeId)

instance Random Primitive where
  randomR (s, e) gen =
    let intify PDouble = 0
        intify PFloat = 1
        intify PInt = 2
        intify (PTime _) = 3
        intify (PCounter _) = 4
        intify PByte = 5
        primify 0 = (\g -> (PDouble, g))
        primify 1 = (\g -> (PFloat, g))
        primify 2 = (\g -> (PInt, g))
        primify 3 = (\g -> let (tr, g')= random g -- :: RandomGen a => (ETimeRep, a)
                            in (PTime tr, g'))
        primify 4 = (\g -> (PCounter Nothing, g))
        primify 5 = (\g -> (PByte, g))
        start_v = intify s
        end_v = intify e
        start = min start_v end_v
        end = 1+ max start_v end_v
        (ival, gen') = next gen
        (result, gen'') = (primify (start + (ival `mod` (end - start)))) gen'
    in (result, gen'')
  random = randomR (PDouble, PByte)

generatePrimitive :: Gen Primitive
generatePrimitive = choose (PDouble, PByte)

generateIdentifier :: Gen String
generateIdentifier = listOf1 $ elements ['a','b','c','d','e','f','g','h','i','j','k','l','m',
                                        'n','o','p','q','r','s','t','u','v','w','x','y','z','_']

generateFrameElement :: Gen FrameElement
generateFrameElement = do
  -- for now, only generate real members
  ty <- generatePrimitive
  diff <- elements [True, False]
  nm <- generateIdentifier
  return $ FMemberElem $ FMember ty nm diff

-- |Generates Frame representations. 'Gen Frame' ?
generateFrame :: Gen Frame
generateFrame = do
  nm <- generateIdentifier
  frelems <- listOf $ generateFrameElement
--  let headElement = 
  return $ Frame nm frelems

instance Arbitrary Primitive where
  arbitrary = generatePrimitive

instance Arbitrary FrameElement where
  arbitrary = generateFrameElement
{-  shrink (FMemberElem (FMember ty nm diff)) =
    (FMemberElem (FMember PDouble nm False)):[
      FMemberElem (FMember t nm b) | (t, b) <- shrink(ty, diff)]
  shrink (FCalculatedElem _ _ _ _ _) = [] -}

instance Arbitrary Frame where
  arbitrary = generateFrame
--  shrink (Frame n (m:ms)) =
--    (Frame n (m:[last ms])) : [Frame n (m:(middle ++ [last ms])) | middle <- shrink (init ms)]

instance Arbitrary ETag where
  arbitrary = do
    key <- generateIdentifier
    value <- generateIdentifier
    return $ Tag key value

instance Arbitrary EOption where
  arbitrary = do
    ty <- choose (0,3) :: Gen Int
    case ty of
      0 -> do names <- arbitrary
              return $ ENamespace names
      1 -> do sfx <- generateIdentifier
              return $ EHeaderSuffix sfx
      2 -> do sfx <- generateIdentifier
              return $ ESourceSuffix sfx
      3 -> do sfx <- generateIdentifier
              return $ EFilePrefix sfx

instance Arbitrary EmitOptions where
  arbitrary = do
    bufNm <- generateIdentifier
    elemCnt <- arbitrary
    let buf = EBuffer bufNm elemCnt
    let lang = ELangCpp
    isRuntmeMt <- arbitrary
    let runtime = ERuntime isRuntmeMt
    tags <- arbitrary
    options <- arbitrary
    timeRep <- arbitrary
    return $ EmitOptions buf lang timeRep runtime tags options

