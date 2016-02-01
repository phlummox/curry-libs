module Test.EasyCheck (

  -- test specification:
  PropIO, yields, sameAs,

  Test, Prop, (==>), for,

  test, is, isAlways, isEventually, prop, uniquely, always, eventually,
  failing, successful, deterministic, (-=-), (#), (<~>), (~>), (<~), (<~~>),

  -- test annotations
  label, trivial, classify, collect, collectAs,

  -- test functions
  easyCheck, easyCheck0, easyCheck1, easyCheck2, easyCheck3, easyCheck4, easyCheck5,
  verboseCheck, verboseCheck0, verboseCheck1, verboseCheck2, verboseCheck3, verboseCheck4,
  verboseCheck5,

  valuesOf, Result(..), result,

  easyCheck', easyCheck1', easyCheck2', easyCheck3', easyCheck4', easyCheck5',

  -- internal operations used by by the CurryCheck tool
  execAssertIO, execPropWithMsg, execProps
  ) where

import AllSolutions ( getAllValues )
import Distribution ( curryCompiler )
import IO           ( hFlush, stdout )
import List         ( delete, nub, group, intersperse, (\\) )
import Maybe        ( catMaybes )
import Random       ( nextInt )
import SearchTree   ( someSearchTree )
import SearchTreeTraversal
import Sort         ( leqList, leqString, mergeSort )

infix  4 `isSameSet`, `isSubsetOf`, `isSameMSet`
infix  1 `is`, `isAlways`, `isEventually`, -=-, #, <~>, ~>, <~, <~~>, `trivial`
infix  1 `yields`, `sameAs`
infixr 0 ==>


-------------------------------------------------------------------------
--- Type of IO assertions.
data PropIO = PropIO (String -> IO (Maybe String))

-- IO tests
-- the IO operation yields a specified result
yields :: IO a -> a -> PropIO
yields act r = PropIO (execIOTest act (return r))

-- two IO operations yield the same result
sameAs :: IO a -> IO a -> PropIO
sameAs a1 a2 = PropIO (execIOTest a1 a2)

-------------------------------------------------------------------------
data Test = Test Result [String] [String]

data Result = Undef | Ok | Falsified [String] | Ambigious [Bool] [String]

type Prop = [Test]

notest :: Test
notest = Test Undef [] []

result :: Test -> Result
result (Test r _ _) = r

setResult :: Result -> Test -> Test
setResult res (Test _ s a) = Test res a s

args, stamp :: Test -> [String]
args  (Test _ a _) = a
stamp (Test _ _ s) = s

updArgs, updStamp :: ([String] -> [String]) -> Test -> Test
updArgs  upd (Test r a s) = Test r (upd a) s
updStamp upd (Test r a s) = Test r a (upd s)

-- Test Specification

test :: a -> ([a] -> Bool) -> Prop
test x f = [setResult res notest]
 where
  xs  = valuesOf x
  res = case valuesOf (f xs) of
          [True]  -> Ok
          [False] -> Falsified (map show xs)
          bs      -> Ambigious bs (map show xs)

is, isAlways, isEventually :: a -> (a -> Bool) -> Prop
is x f = test x (\xs -> case xs of [y] -> f y; _ -> False)
isAlways x  = test x . all
isEventually x = test x . any

prop, uniquely, always, eventually :: Bool -> Prop
prop       = uniquely
uniquely   = (`is`id)
always     = (`isAlways`id)
eventually = (`isEventually`id)

failing, successful, deterministic :: _ -> Prop
failing x = test x null
successful x = test x (not . null)
deterministic x = x `is` const True

(-=-) :: a -> a -> Prop
x -=- y = (x,y) `is` uncurry (==)

(#) :: _ -> Int -> Prop
x # n = test x ((n==) . length . nub)

-- (<~~>) provides multi-set semantics for EasyCheck
(<~>), (~>), (<~), (<~~>) :: a -> a -> Prop
x <~>  y = test x (isSameSet (valuesOf y))
x  ~>  y = test x (isSubsetOf (valuesOf y))
x  <~  y = test x (`isSubsetOf` (valuesOf y))
x <~~> y = test x (isSameMSet (valuesOf y))

isSameSet, isSubsetOf, subset, isSameMSet :: [a] -> [a] -> Bool
xs `isSameSet` ys = xs' `subset` ys' && ys' `subset` xs'
 where xs' = nub xs; ys' = nub ys
xs `isSubsetOf` ys = nub xs `subset` ys
xs `subset` ys = null (xs\\ys)
-- compare to lists if they represent the same multi-set
[]     `isSameMSet` ys = ys == []
(x:xs) `isSameMSet` ys
  | x `elem` ys        = xs `isSameMSet` (delete x ys)
  | otherwise          = False

--- A conditional property is tested if the condition evaluates to `True`.
(==>) :: Bool -> Prop -> Prop
cond ==> p =
  if True `elem` valuesOf cond
  then p
  else [notest]

forAll :: (b -> Prop) -> a -> (a -> b) -> Prop
forAll c x f
  = diagonal [[ updArgs (show y:) t | t <- c (f y) ] | y <- valuesOf x ]

for :: a -> (a -> Prop) -> Prop
for = forAll id

-- Test Annotations

label :: String -> Prop -> Prop
label = map . updStamp . (:)

classify :: Bool -> String -> Prop -> Prop
classify True  name = label name
classify False _    = id

trivial :: Bool -> Prop -> Prop
trivial = (`classify`"trivial")

collect :: a -> Prop -> Prop
collect = label . show

collectAs :: String -> a -> Prop -> Prop
collectAs name = label . ((name++": ")++) . show

-- Test Functions

data Config = Config Int Int (Int -> [String] -> String)

maxTest, maxFail :: Config -> Int
maxTest (Config n _ _) = n
maxFail (Config _ n _) = n

every :: Config -> Int -> [String] -> String
every (Config _ _ f) = f

setEvery :: (Int -> [String] -> String) -> Config -> Config
setEvery f (Config n m _) = Config n m f

easy :: Config
--easy = Config 1000 10000
easy = Config 100 10000
        (\n _ -> let s = ' ':show (n+1) in s ++ [ chr 8 | _ <- s ])

verbose :: Config
verbose = setEvery (\n xs -> show n ++ ":\n" ++ unlines xs) easy

easyCheck, verboseCheck :: String -> Prop -> IO Bool
easyCheck    = check easy
verboseCheck = check verbose

suc :: (a -> Prop) -> (b -> a) -> Prop
suc n = forAll n unknown

easyCheck0, verboseCheck0 :: String -> Prop -> IO Bool
easyCheck0 = easyCheck
verboseCheck0 = verboseCheck

easyCheck1 :: String -> (_ -> Prop) -> IO Bool
easyCheck1 msg = easyCheck msg . suc id

easyCheck2 :: String -> (_ -> _ -> Prop) -> IO Bool
easyCheck2 msg = easyCheck msg . suc (suc id)

easyCheck3 :: String -> (_ -> _ -> _ -> Prop) -> IO Bool
easyCheck3 msg = easyCheck msg . suc (suc (suc id))

easyCheck4 :: String -> (_ -> _ -> _ -> _ -> Prop) -> IO Bool
easyCheck4 msg = easyCheck msg . suc (suc (suc (suc id)))

easyCheck5 :: String -> (_ -> _ -> _ -> _ -> _ -> Prop) -> IO Bool
easyCheck5 msg = easyCheck msg . suc (suc (suc (suc (suc id))))

verboseCheck1 :: String -> (_ -> Prop) -> IO Bool
verboseCheck1 msg = verboseCheck msg . suc id

verboseCheck2 :: String -> (_ -> _ -> Prop) -> IO Bool
verboseCheck2 msg = verboseCheck msg . suc (suc id)

verboseCheck3 :: String -> (_ -> _ -> _ -> Prop) -> IO Bool
verboseCheck3 msg = verboseCheck msg . suc (suc (suc id))

verboseCheck4 :: String -> (_ -> _ -> _ -> _ -> Prop) -> IO Bool
verboseCheck4 msg = verboseCheck msg . suc (suc (suc (suc id)))

verboseCheck5 :: String -> (_ -> _ -> _ -> _ -> _ -> Prop) -> IO Bool
verboseCheck5 msg = verboseCheck msg . suc (suc (suc (suc (suc id))))


check :: Config -> String -> Prop -> IO Bool
check config msg p = tests config msg p 0 0 []

tests :: Config -> String -> [Test] -> Int -> Int -> [[String]] -> IO Bool
tests _ msg [] ntest _ stamps = done (msg ++ ":\n Passed") ntest stamps >> return True
tests config msg (t:ts) ntest nfail stamps
  | ntest == maxTest config = done (msg ++ ":\n OK, passed") ntest stamps >> return True
  | nfail == maxFail config = done (msg ++ ":\n Arguments exhausted after") ntest stamps >> return False
  | otherwise = do
      putStr (every config ntest (args t))
      case result t of
        Undef -> tests config msg ts ntest (nfail+1) stamps
        Ok    -> tests config msg ts (ntest+1) nfail (stamp t:stamps)
        Falsified results -> do
          putStr $
            msg ++ " failed\n" ++
            "Falsified by " ++ nth (ntest+1) ++ " test" ++
            (if null (args t) then "." else ".\nArguments:") ++ "\n" ++
            unlines (args t) ++
            if null results then "no result\n"
              else "Results:\n" ++ unlines (nub results)
          return False
        Ambigious bs results -> do
          putStr $
            "Ambigious property yields " ++ show bs ++ " for " ++
            nth (ntest+1) ++ " test" ++
            (if null (args t) then "." else ".\nArguments:") ++ "\n" ++
            unlines (args t) ++
            if null results then "no result\n"
              else "Results:\n" ++ unlines (nub results)
          return False

check' :: Config -> Prop -> Result
check' config p = tests' config p 0 0 []

tests' :: Config -> [Test] -> Int -> Int -> [[String]] -> Result
tests' config (t:ts) ntest nfail stamps
  | ntest == maxTest config = Ok
  | nfail == maxFail config = Falsified ["Arguments exhausted after " ++ show ntest ++ " test"]
  | otherwise = case result t of
                     Undef     -> tests' config ts ntest (nfail+1) stamps
                     Ok        -> tests' config ts (ntest+1) nfail stamps
                     res       -> res

easyCheck' :: Prop -> Result
easyCheck' = check' easy

easyCheck1' :: (_ -> Prop) -> Result
easyCheck1' = easyCheck' . suc id

easyCheck2' :: (_ -> _ -> Prop) -> Result
easyCheck2' = easyCheck' . suc (suc id)

easyCheck3' :: (_ -> _ -> _ -> Prop) -> Result
easyCheck3' = easyCheck' . suc (suc (suc id))

easyCheck4' :: (_ -> _ -> _ -> _ -> Prop) -> Result
easyCheck4' = easyCheck' . suc (suc (suc (suc id)))

easyCheck5' :: (_ -> _ -> _ -> _ -> _ -> Prop) -> Result
easyCheck5' = easyCheck' . suc (suc (suc (suc (suc id))))

nth :: Int -> String
nth n = case n of 1 -> "first"; 2 -> "second"; 3 -> "third"; _ -> show n++ "th"

done :: String -> Int -> [[String]] -> IO ()
done mesg ntest stamps
  = putStr $ mesg ++ " " ++ show ntest ++ " test"
          ++ (if ntest >= 2 then "s" else "") ++ table
 where
  table = display
        . map entry
        . reverse
        . mergeSort (leqPair (<=) (leqList leqString))
        . map pairLength
        . group
        . mergeSort (leqList leqString)
        . filter (not . null)
        $ stamps

  display []         = ".\n"
  display [x]        = " - " ++ x ++ ".\n"
  display xs@(_:_:_) = ".\n" ++ unlines (map (++".") xs)

  pairLength xss@(xs:_) = (length xss,xs)

  entry (n,xs) = percentage n ntest ++ " " ++ concat (intersperse ", " xs)

  percentage n _ = let s = show n -- ((100*n)`div`m)
                    in replicate (5-length s) ' ' ++ s -- ++ "%"

-- Auxiliary Functions

leqPair :: (a -> a -> Bool) -> (b -> b -> Bool) -> ((a,b) -> (a,b) -> Bool)
leqPair leqa leqb (x1,y1) (x2,y2)
  | x1 == x2  = leqb y1 y2
  | otherwise = leqa x1 x2

valuesOf :: a -> [a]
valuesOf
  -- = depthDiag . someSearchTree . (id$##)
  -- = rndDepthDiag 0 . someSearchTree . (id$##)
  -- = levelDiag . someSearchTree . (id$##)
  -- = rndLevelDiag 0 . someSearchTree . (id$##)
   = rndLevelDiagFlat 5 0 . someSearchTree . (id$##)
  -- = allValuesB . someSearchTree . (id$##)

-------------------------------------------------------------------------
-- Internal  operation used by currycheck to check an IO assertion
execAssertIO :: PropIO -> String -> IO (Maybe String)
execAssertIO p msg = catchNDIO msg $
  case p of PropIO propio -> propio msg

execIOTest :: IO a -> IO a -> String -> IO (Maybe String)
execIOTest act1 act2 msg =
   catch (do putStr (msg++": ") >> hFlush stdout
             r1 <- act1
             r2 <- act2
             if r1 == r2
               then putStrLn "OK" >>  return Nothing
               else do putStrLn $ "FAILED!\nResults: " ++ show (r1,r2)
                       return (Just msg)
         )
         (\err -> do putStrLn $ "EXECUTION FAILURE:\n" ++ showError err
                     return (Just msg)
         )

-- Execute I/O action for assertion checking and report any failure
-- or non-determinism.
catchNDIO :: String -> IO (Maybe String) -> IO (Maybe String)
catchNDIO msg testact =
  if curryCompiler == "kics2"
  then -- specific handling for KiCS2 since it might report non-det errors
       -- even if there is only one result value, e.g., in functional patterns
       getAllValues testact >>= checkIOActions
  else catch testact
             (\e -> putStrLn (msg++": EXECUTION FAILURE: "++showError e) >>
                    return (Just msg))
 where
  checkIOActions results
    | null results
     = putStrLn (msg++": FAILURE: computation failed") >> return (Just msg)
    | not (null (tail results))
     = putStrLn (msg++": FAILURE: computation is non-deterministic") >>
       return (Just msg)
    | otherwise = head results

--- Safely executes a property, i.e., catch all exceptions that might occur.
execPropWithMsg :: String -> IO Bool -> IO (Maybe String)
execPropWithMsg msg execprop = catchNDIO msg $ do
  b <- catch execprop
             (\e -> putStrLn (msg ++ ": EXECUTION FAILURE:\n" ++ showError e)
                    >> return False)
  return (if b then Nothing else Just msg)

-- Runs a sequence of tests and
-- yields a new exit status based on the succesfully executed tests.
execProps :: [IO (Maybe String)] -> IO Int
execProps props = do
  propresults <- sequenceIO props
  let failedmsgs = catMaybes propresults
  if null failedmsgs
   then return 0
   else do putStrLn $ line ++
                      "\nFAILURE OCCURRED IN SOME TESTS:\n" ++
                      unlines failedmsgs ++ line
           return 1
 where
   line = take 78 (repeat '=')

-------------------------------------------------------------------------