{-# LANGUAGE DeriveDataTypeable #-}

module Yi.Buffer.TextUnit
    ( TextUnit(..)
    , outsideUnit
    , leftBoundaryUnit
    , unitWord
    , unitViWord
    , unitViWORD
    , unitViWordAnyBnd
    , unitViWORDAnyBnd
    , unitViWordOnLine
    , unitViWORDOnLine
    , unitDelimited
    , unitSentence, unitEmacsParagraph, unitParagraph
    , isAnySep, unitSep, unitSepThisLine, isWordChar
    , moveB, maybeMoveB
    , transformB, transposeB
    , regionOfB, regionOfNonEmptyB, regionOfPartB
    , regionWithTwoMovesB
    , regionOfPartNonEmptyB, regionOfPartNonEmptyAtB
    , readPrevUnitB, readUnitB
    , untilB, doUntilB_, untilB_, whileB, doIfCharB
    , atBoundaryB
    , numberOfB
    , deleteB, genMaybeMoveB
    , genMoveB, BoundarySide(..), genAtBoundaryB
    , checkPeekB
    , halfUnit
    , deleteUnitB
    ) where

import Prelude (length, subtract)
import Yi.Prelude

import Data.Char

import Yi.Buffer.Basic
import Yi.Buffer.Misc
import Yi.Buffer.Region

-- | Designate a given "unit" of text.
data TextUnit = Character -- ^ a single character
              | Line  -- ^ a line of text (between newlines)
              | VLine -- ^ a "vertical" line of text (area of text between two characters at the same column number)
              | Document -- ^ the whole document
              | GenUnit {genEnclosingUnit :: TextUnit,
                         genUnitBoundary :: Direction -> BufferM Bool}
      -- there could be more text units, like Page, Searched, etc. it's probably a good
      -- idea to use GenUnit though.
                deriving Typeable

-- | Turns a unit into its "negative" by inverting the boundaries. For example,
-- @outsideUnit unitViWord@ will be the unit of spaces between words. For units
-- without boundaries ('Character', 'Document', ...), this is the identity
-- function.
outsideUnit :: TextUnit -> TextUnit
outsideUnit (GenUnit enclosing boundary) = GenUnit enclosing (boundary . reverseDir)
outsideUnit x = x -- for a lack of better definition

-- | Common boundary checking function: run the condition on @siz@ characters in specified direction
-- shifted by specified offset.
genBoundary :: Int -> (String -> Bool) -> Direction -> BufferM Bool
genBoundary ofs condition dir = condition <$> peekB
  where -- | read some characters in the specified direction
        peekB = savingPointB $
          do moveN $ mayNegate $ ofs
             fmap snd <$> (indexedStreamB dir =<< pointB)
        mayNegate = case dir of Forward -> id
                                Backward -> negate

-- | a word as in use in Emacs (fundamental mode)
unitWord :: TextUnit
unitWord = GenUnit Document $ \direction -> checkPeekB (-1) [isWordChar, not . isWordChar] direction

-- ^ delimited on the left and right by given characters, boolean argument tells if whether those are included.
unitDelimited :: Char -> Char -> Bool -> TextUnit
unitDelimited left right included = GenUnit Document $ \direction ->
   case (included,direction) of
       (False, Backward) -> checkPeekB 0 [(== left)] Backward
       (False, Forward)  -> (== right) <$> readB
       (True,  Backward) -> checkPeekB (-1) [(== left)] Backward
       (True,  Forward)  -> checkPeekB 0 [(== right)] Backward

isWordChar :: Char -> Bool
isWordChar x = isAlphaNum x || x == '_'

isNl :: Char -> Bool
isNl = (== '\n')

-- | Tells if a char can end a sentence ('.', '!', '?').
isEndOfSentence :: Char -> Bool
isEndOfSentence = (`elem` ".!?")

-- | Verifies that the list matches all the predicates, pairwise.
-- If the list is "too small", then return 'False'.
checks :: [a -> Bool] -> [a] -> Bool
checks [] _ = True
checks _ [] = False
checks (p:ps) (x:xs) = p x && checks ps xs


checkPeekB :: Int -> [Char -> Bool] -> Direction -> BufferM Bool
checkPeekB offset conds = genBoundary offset (checks conds)

atViWordBoundary :: (Char -> Int) -> Direction -> BufferM Bool
atViWordBoundary charType = genBoundary (-1) $ \cs -> case cs of
      (c1:c2:_) -> isNl c1 && isNl c2 -- stop at empty lines
              || not (isSpace c1) && (charType c1 /= charType c2)
      _ -> True

atAnyViWordBoundary :: (Char -> Int) -> Direction -> BufferM Bool
atAnyViWordBoundary charType = genBoundary (-1) $ \cs -> case cs of
      (c1:c2:_) -> isNl c1 || isNl c2 || charType c1 /= charType c2
      _ -> True

atViWordBoundaryOnLine :: (Char -> Int) -> Direction -> BufferM Bool
atViWordBoundaryOnLine charType = genBoundary (-1)  $ \cs -> case cs of
      (c1:c2:_) -> isNl c1 || isNl c2 || not (isSpace c1) && charType c1 /= charType c2
      _ -> True

unitViWord :: TextUnit
unitViWord = GenUnit Document $ atViWordBoundary viWordCharType

unitViWORD :: TextUnit
unitViWORD = GenUnit Document $ atViWordBoundary viWORDCharType

unitViWordAnyBnd :: TextUnit
unitViWordAnyBnd = GenUnit Document $ atAnyViWordBoundary viWordCharType

unitViWORDAnyBnd :: TextUnit
unitViWORDAnyBnd = GenUnit Document $ atAnyViWordBoundary viWORDCharType

unitViWordOnLine :: TextUnit
unitViWordOnLine = GenUnit Document $ atViWordBoundaryOnLine viWordCharType

unitViWORDOnLine :: TextUnit
unitViWORDOnLine = GenUnit Document $ atViWordBoundaryOnLine viWORDCharType

viWordCharType :: Char -> Int
viWordCharType c | isSpace c    = 1
                 | isWordChar c = 2
                 | otherwise    = 3

viWORDCharType :: Char -> Int
viWORDCharType c | isSpace c = 1
                 | otherwise = 2

-- | Separator characters (space, tab, unicode separators). Most of the units
-- above attempt to identify "words" with various punctuation and symbols included
-- or excluded. This set of units is a simple inverse: it is true for "whitespace"
-- or "separators" and false for anything that is not (letters, numbers, symbols,
-- punctuation, whatever).

isAnySep :: Char -> Bool
isAnySep c = isSeparator c || isSpace c || generalCategory c `elem` [ Space, LineSeparator, ParagraphSeparator ]

atSepBoundary :: Direction -> BufferM Bool
atSepBoundary = genBoundary (-1) $ \cs -> case cs of
    (c1:c2:_) -> isNl c1 || isNl c2 || isAnySep c1 /= isAnySep c2
    _ -> True

-- | unitSep is true for any kind of whitespace/separator
unitSep :: TextUnit
unitSep = GenUnit Document atSepBoundary

-- | unitSepThisLine is true for any kind of whitespace/separator on this line only
unitSepThisLine :: TextUnit
unitSepThisLine = GenUnit Line atSepBoundary


-- | Is the point at a @Unit@ boundary in the specified @Direction@?
atBoundary :: TextUnit -> Direction -> BufferM Bool
atBoundary Document Backward = (== 0) <$> pointB
atBoundary Document Forward  = (>=)   <$> pointB <*> sizeB
atBoundary Character _ = return True
atBoundary VLine _ = return True -- a fallacy; this needs a little refactoring.
atBoundary Line direction = checkPeekB 0 [isNl] direction
atBoundary (GenUnit _ atBound) dir = atBound dir

enclosingUnit :: TextUnit -> TextUnit
enclosingUnit (GenUnit enclosing _) = enclosing
enclosingUnit _ = Document

atBoundaryB :: TextUnit -> Direction -> BufferM Bool
atBoundaryB Document d = atBoundary Document d
atBoundaryB u d = (||) <$> atBoundary u d <*> atBoundaryB (enclosingUnit u) d

-- | Paragraph to implement emacs-like forward-paragraph/backward-paragraph
unitEmacsParagraph :: TextUnit
unitEmacsParagraph = GenUnit Document $ checkPeekB (-2) [not . isNl, isNl, isNl]

-- | Paragraph that begins and ends in the paragraph, not the empty lines surrounding it.
unitParagraph :: TextUnit
unitParagraph = GenUnit Document $ checkPeekB (-1) [not . isNl, isNl, isNl]

unitSentence :: TextUnit
unitSentence = GenUnit unitEmacsParagraph $ \dir -> checkPeekB (if dir == Forward then -1 else 0) (mayReverse dir [isEndOfSentence, isSpace]) dir

-- | Unit that have its left and right boundaries at the left boundary of the argument unit.
leftBoundaryUnit :: TextUnit -> TextUnit
leftBoundaryUnit u = GenUnit Document $ (\_dir -> atBoundaryB u Backward)

-- | @genAtBoundaryB u d s@ returns whether the point is at a given boundary @(d,s)@ .
-- Boundary @(d,s)@ , taking Word as example, means:
--      Word
--     ^^  ^^
--     12  34
-- 1: (Backward,OutsideBound)
-- 2: (Backward,InsideBound)
-- 3: (Forward,InsideBound)
-- 4: (Forward,OutsideBound)
--
-- rules:
-- genAtBoundaryB u Backward InsideBound  = atBoundaryB u Backward
-- genAtBoundaryB u Forward  OutsideBound = atBoundaryB u Forward
genAtBoundaryB :: TextUnit -> Direction -> BoundarySide -> BufferM Bool
genAtBoundaryB u d s = withOffset (off u d s) $ atBoundaryB u d
    where withOffset 0 f = f
          withOffset ofs f = savingPointB (((ofs +) <$> pointB) >>= moveTo >> f)
          off _    Backward  InsideBound = 0
          off _    Backward OutsideBound = 1
          off _    Forward   InsideBound = 1
          off _    Forward  OutsideBound = 0


numberOfB :: TextUnit -> TextUnit -> BufferM Int
numberOfB unit containingUnit = savingPointB $ do
                   maybeMoveB containingUnit Backward
                   start <- pointB
                   moveB containingUnit Forward
                   end <- pointB
                   moveTo start
                   length <$> untilB ((>= end) <$> pointB) (moveB unit Forward)

whileB :: BufferM Bool -> BufferM a -> BufferM [a]
whileB cond = untilB (not <$> cond)

-- | Repeat an action until the condition is fulfilled or the cursor stops moving.
-- The Action may be performed zero times.
untilB :: BufferM Bool -> BufferM a -> BufferM [a]
untilB cond f = do
  stop <- cond
  if stop then return [] else doUntilB cond f

-- | Repeat an action until the condition is fulfilled or the cursor stops moving.
-- The Action is performed at least once.
doUntilB :: BufferM Bool -> BufferM a -> BufferM [a]
doUntilB cond f = loop
      where loop = do
              p <- pointB
              x <- f
              p' <- pointB
              stop <- cond
              (x:) <$> if p /= p' && not stop
                then loop
                else return []

doUntilB_ :: BufferM Bool -> BufferM a -> BufferM ()
doUntilB_ cond f = doUntilB cond f >> return () -- maybe do an optimized version?

untilB_ :: BufferM Bool -> BufferM a -> BufferM ()
untilB_ cond f = untilB cond f >> return () -- maybe do an optimized version?

-- | Do an action if the current buffer character passes the predicate
doIfCharB :: (Char -> Bool) -> BufferM a -> BufferM ()
doIfCharB p o = readB >>= \c -> if p c then o >> return () else return ()


-- | Boundary side
data BoundarySide = InsideBound | OutsideBound
    deriving Eq

-- | Generic move operation
-- Warning: moving To the (OutsideBound, Backward) bound of Document is impossible (offset -1!)
-- @genMoveB u b d@: move in direction d until encountering boundary b or unit u. See 'genAtBoundaryB' for boundary explanation.
genMoveB :: TextUnit -> (Direction, BoundarySide) -> Direction -> BufferM ()
genMoveB Document (Forward,InsideBound) Forward = moveTo =<< subtract 1 <$> sizeB
genMoveB Document _                     Forward = moveTo =<< sizeB
genMoveB Document _ Backward = moveTo 0 -- impossible to go outside beginning of doc.
genMoveB Character _ Forward  = rightB
genMoveB Character _ Backward = leftB
genMoveB VLine     _ Forward  =
  do ofs <- lineMoveRel 1
     when (ofs < 1) (maybeMoveB Line Forward)
genMoveB VLine _ Backward = lineUp
genMoveB unit (boundDir, boundSide) moveDir =
  doUntilB_ (genAtBoundaryB unit boundDir boundSide) (moveB Character moveDir)

-- | Generic maybe move operation.
-- As genMoveB, but don't move if we are at boundary already.
genMaybeMoveB :: TextUnit -> (Direction, BoundarySide) -> Direction -> BufferM ()
genMaybeMoveB Document boundSpec moveDir = genMoveB Document boundSpec moveDir
   -- optimized case for Document
genMaybeMoveB Line (Backward, InsideBound) Backward = moveTo =<< solPointB
   -- optimized case for begin of Line
genMaybeMoveB unit (boundDir, boundSide) moveDir =
  untilB_ (genAtBoundaryB unit boundDir boundSide) (moveB Character moveDir)


-- | Move to the next unit boundary
moveB :: TextUnit -> Direction -> BufferM ()
moveB u d = genMoveB u (d, case d of Forward -> OutsideBound; Backward -> InsideBound) d


-- | As 'moveB', unless the point is at a unit boundary

-- So for example here moveToEol = maybeMoveB Line Forward;
-- in that it will move to the end of current line and nowhere if we
-- are already at the end of the current line. Similarly for moveToSol.

maybeMoveB :: TextUnit -> Direction -> BufferM ()
maybeMoveB u d = genMaybeMoveB u (d, case d of Forward -> OutsideBound; Backward -> InsideBound) d

transposeB :: TextUnit -> Direction -> BufferM ()
transposeB unit direction = do
  moveB unit (reverseDir direction)
  w0 <- pointB
  moveB unit direction
  w0' <- pointB
  moveB unit direction
  w1' <- pointB
  moveB unit (reverseDir direction)
  w1 <- pointB
  swapRegionsB (mkRegion w0 w0') (mkRegion w1 w1')
  moveTo w1'

transformB :: (String -> String) -> TextUnit -> Direction -> BufferM ()
transformB f unit direction = do
  p <- pointB
  moveB unit direction
  q <- pointB
  let r = mkRegion p q
  replaceRegionB r =<< f <$> readRegionB r

-- | Delete between point and next unit boundary, return the deleted region.
deleteB :: TextUnit -> Direction -> BufferM ()
deleteB unit dir = deleteRegionB =<< regionOfPartNonEmptyB unit dir

regionWithTwoMovesB :: BufferM a -> BufferM b -> BufferM Region
regionWithTwoMovesB move1 move2 =
    savingPointB $ mkRegion <$> (move1 >> pointB) <*> (move2 >> pointB)

-- | Region of the whole textunit where the current point is.
regionOfB :: TextUnit -> BufferM Region
regionOfB unit = regionWithTwoMovesB (maybeMoveB unit Backward) (maybeMoveB unit Forward)

-- An alternate definition would be the following, but it can return two units if the current point is between them.
-- eg.  "word1 ^ word2" would return both words.
-- regionOfB unit = mkRegion
--                  <$> pointAfter (maybeMoveB unit Backward)
--                  <*> destinationOfMoveB (maybeMoveB unit Forward)
-- | Non empty region of the whole textunit where the current point is.
regionOfNonEmptyB :: TextUnit -> BufferM Region
regionOfNonEmptyB unit = savingPointB $
  mkRegion <$> (maybeMoveB unit Backward >> pointB) <*> (moveB unit Forward >> pointB)

-- | Region between the point and the next boundary.
-- The region is empty if the point is at the boundary.
regionOfPartB :: TextUnit -> Direction -> BufferM Region
regionOfPartB unit dir = mkRegion <$> pointB <*> destinationOfMoveB (maybeMoveB unit dir)

-- | Non empty region between the point and the next boundary,
-- In fact the region can be empty if we are at the end of file.
regionOfPartNonEmptyB :: TextUnit -> Direction -> BufferM Region
regionOfPartNonEmptyB unit dir = mkRegion <$> pointB <*> destinationOfMoveB (moveB unit dir)

-- | Non empty region at given point and the next boundary,
regionOfPartNonEmptyAtB :: TextUnit -> Direction -> Point -> BufferM Region
regionOfPartNonEmptyAtB unit dir p = do
    oldP <- pointB
    moveTo p
    r <- regionOfPartNonEmptyB unit dir
    moveTo oldP
    return r

readPrevUnitB :: TextUnit -> BufferM String
readPrevUnitB unit = readRegionB =<< regionOfPartNonEmptyB unit Backward

readUnitB :: TextUnit -> BufferM String
readUnitB = readRegionB <=< regionOfB

halfUnit :: Direction -> TextUnit -> TextUnit
halfUnit dir (GenUnit enclosing boundary) =
  GenUnit enclosing (\d -> if d == dir then boundary d else return False)
halfUnit _dir tu = tu

deleteUnitB :: TextUnit -> Direction -> BufferM ()
deleteUnitB unit dir = deleteRegionB =<< regionOfPartNonEmptyB unit dir

