{-# LANGUAGE CPP, OverloadedStrings, TupleSections, ScopedTypeVariables #-}

module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Char (isLower, toLower, isDigit)
import           Data.Maybe
import           Data.Monoid
import qualified Data.ByteString as B
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy as TL
import           Data.Time.Clock (getCurrentTime, diffUTCTime)
import           Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import           Filesystem (removeTree, isFile, getWorkingDirectory, setWorkingDirectory, copyFile)
import           Filesystem.Path ( replaceExtension, basename, directory, extension, addExtension
                                 , filename, addExtensions, dropExtensions)
import           Filesystem.Path.CurrentOS (encodeString, decodeString)
import           Prelude hiding (FilePath)
import           Shelly
import           System.Environment (getArgs, getEnv)
import           System.Exit (ExitCode(..), exitFailure)
import           System.Process (readProcessWithExitCode)
import           System.Random (randomRIO)
import           Test.Framework
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit.Base (assertBool, assertFailure, assertEqual, Assertion)
import qualified Data.Yaml as Yaml
import           Data.Yaml (FromJSON(..), Value(..), (.:?), (.!=))
import           Data.Default
import qualified Control.Exception as Ex
#if __GLASGOW_HASKELL__ >= 707
import           Text.Read (readMaybe)
#else
import           Safe

readMaybe = readMay
#endif

main = do
  args <- getArgs
  let args' = filter (/="--benchmark") args
  checkRequiredPackages
  onlyOpt <- getEnvOpt "GHCJS_TEST_ONLYOPT"
  onlyUnopt <- getEnvOpt "GHCJS_TEST_ONLYUNOPT"
  if any (=="--benchmark") args
    then (\bs -> defaultMainWithArgs bs args') =<< benchmarks
    else do
      if onlyOpt && onlyUnopt
        then putStrLn "warning: nothing to do, optimized and unoptimized disabled"
        else defaultMain =<< tests onlyOpt onlyUnopt

benchmarks = do
  nofib <- allTestsIn benchmark "test/nofib"
  return [ testGroup "Benchmarks from nofib" nofib
         ]

tests onlyOpt onlyUnopt = do
  let test = TestOpts onlyOpt onlyUnopt
  fay     <- allTestsIn test "test/fay"
  ghc     <- allTestsIn test "test/ghc"
  arith   <- allTestsIn test "test/arith"
  integer <- allTestsIn test "test/integer"
  pkg     <- allTestsIn test "test/pkg"
  conc    <- allTestsIn test "test/conc"
  ffi     <- allTestsIn test "test/ffi"
  return [ testGroup "Tests from the Fay testsuite" fay
         , testGroup "Tests from the GHC testsuite" ghc
         , testGroup "Arithmetic" arith
         , testGroup "Integer" integer
         , testGroup "Concurrency" conc
         , testGroup "JavaScript interaction through FFI" ffi
         , testGroup "Tests imported from packages" pkg
         ]

-- warn if any of these are not installed
requiredPackages :: [TL.Text]
requiredPackages = [ "ghc-prim"
                   , "integer-gmp"
                   , "base"
                   , "containers"
                   , "array"
                   , "deepseq"
                   , "template-haskell"
                   , "random"
                   , "syb"
                   , "transformers"
                   , "text"
                   , "parallel"
                   , "ghcjs-base"
                   , "QuickCheck"
                   , "old-time"
                   , "vector"
                   ]

data TestOpts = TestOpts { disableUnopt :: Bool
                         , disableOpt   :: Bool
                         }
benchmark = TestOpts True False

-- settings for a single test
data TestSettings =
  TestSettings { tsDisableNode         :: Bool
               , tsDisableSpiderMonkey :: Bool
               , tsDisableOpt          :: Bool
               , tsDisableUnopt        :: Bool
               , tsDisabled            :: Bool
               , tsArguments           :: [String] -- ^ command line arguments
               , tsCopyFiles           :: [String] -- ^ copy these files to the dir where the test is run
               } deriving (Eq, Show)

instance Default TestSettings where
  def = TestSettings False False False False False [] []

instance FromJSON TestSettings where
  parseJSON (Object o) = TestSettings <$> o .:? "disableNode"         .!= False
                                      <*> o .:? "disableSpiderMonkey" .!= False
                                      <*> o .:? "disableOpt"          .!= False
                                      <*> o .:? "disableUnopt"        .!= False
                                      <*> o .:? "disabled"            .!= False
                                      <*> o .:? "arguments"           .!= []
                                      <*> o .:? "copyFiles"           .!= []

  parseJSON _ = mempty

{-
  run all files in path as stdio tests
  tests are:
   - .hs or .lhs files
   - that start with a lowercase letter
-}
-- allTestsIn :: FilePath -> IO [Test]
allTestsIn testOpts path = shelly $
  map (stdioTest testOpts) <$> findWhen (return . isTestFile) path
  where
    testFirstChar c = isLower c || isDigit c
    isTestFile file =
      (extension file == Just "hs" || extension file == Just "lhs") &&
      ((maybe False testFirstChar . listToMaybe . encodeString . basename $ file) ||
      (basename file == "Main"))

{-
  a stdio test tests two things:
  stdout/stderr/exit output must be either:
     - the same as filename.out/filename.err/filename.exit (if any exists)
     - the same as runhaskell output (otherwise)
  the javascript is run with `js' (SpiderMonkey) and `node` (v8)
  if they're in $PATH.
-}
data StdioResult = StdioResult { stdioExit :: ExitCode
                               , stdioOut :: Text
                               , stdioErr :: Text
                               } -- deriving (Show)
instance Eq StdioResult where
  (StdioResult e1 ou1 er1) == (StdioResult e2 ou2 er2) =
    e1 == e2 && (T.strip ou1 == T.strip ou2) && (T.strip er1 == T.strip er2)

instance Show StdioResult where
  show (StdioResult ex out err) =
    "\n>>> exit: " ++ show ex ++ "\n>>> stdout >>>\n" ++
    T.unpack out ++ "\n<<< stderr >>>\n" ++ T.unpack err ++ "\n<<<\n"

stdioTest :: TestOpts -> FilePath -> Test
stdioTest testOpts file = testCase (encodeString file) (stdioAssertion testOpts file)

stdioAssertion :: TestOpts -> FilePath -> Assertion
stdioAssertion testOpts file = do
  putStrLn ("running test: " ++ encodeString file)
  mexpected <- stdioExpected file
  case mexpected of
    Nothing -> putStrLn "test disabled"
    Just expected -> do
      actual <- runGhcjsResult testOpts file
      when (null actual) (putStrLn "warning: no test results")
      forM_ actual $ \((a,t),d) -> do
        assertEqual (encodeString file ++ ": " ++ d) expected a
        putStrLn ("    " ++ (padTo 40 d) ++ " " ++ show t ++ "ms")

padTo :: Int -> String -> String
padTo n xs | l < n     = xs ++ replicate (n-l) ' '
           | otherwise = xs
  where l = length xs

stdioExpected :: FilePath -> IO (Maybe StdioResult)
stdioExpected file = do
  settings <- settingsFor file
  if tsDisabled settings
    then return Nothing
    else do
      xs@[mex,mout,merr] <- mapM (readFilesIfExists.(map (replaceExtension file)))
             [["exit"], ["stdout", "out"], ["stderr","err"]]
      if any isJust xs
        then return . Just $ StdioResult (fromMaybe ExitSuccess $ readExitCode =<< mex)
                               (fromMaybe "" mout) (fromMaybe "" merr)
        else do
          mr <- runhaskellResult settings file
          case mr of
            Nothing    -> assertFailure "cannot run `runhaskell'" >> return undefined
            Just (r,t) -> return (Just r)

readFileIfExists :: FilePath -> IO (Maybe Text)
readFileIfExists file = do
  e <- isFile file
  case e of
    False -> return Nothing
    True  -> Just <$> T.readFile (encodeString file)

readFilesIfExists :: [FilePath] -> IO (Maybe Text)
readFilesIfExists [] = return Nothing
readFilesIfExists (x:xs) = do
  r <- readFileIfExists x
  if (isJust r)
    then return r
    else readFilesIfExists xs

-- test settings
settingsFor :: FilePath -> IO TestSettings
settingsFor file = do
  e <- isFile settingsFile
  case e of
    False -> return def
    True -> do
      cfg <- B.readFile settingsFile'
      case Yaml.decodeEither cfg of
        Left err -> errDef
        Right t  -> return t
  where
    errDef = do
      putStrLn $ "error in test settings: " ++ settingsFile'
      putStrLn "running test with default settings"
      return def
    settingsFile = replaceExtension file "settings"
    settingsFile' = encodeString settingsFile

runhaskellResult :: TestSettings -> FilePath -> IO (Maybe (StdioResult, Integer))
runhaskellResult settings file = do
    cd <- getWorkingDirectory
    let args = tsArguments settings
    setWorkingDirectory (cd </> directory file)
    r <- runProcess "runhaskell" ([ includeOpt file, "-w"
                                 , encodeString $ filename file] ++ args) ""
    setWorkingDirectory cd
    return r

includeOpt :: FilePath -> String
includeOpt fp = "-i" <> encodeString (directory fp)

extraJsFiles :: FilePath -> IO [String]
extraJsFiles file =
  let jsFile = addExtensions (dropExtensions file) ["foreign", "js"]
  in do
    e <- isFile jsFile
    return $ if e then [encodeString jsFile] else []

runGhcjsResult :: TestOpts -> FilePath -> IO [((StdioResult, Integer), String)]
runGhcjsResult opts file = do
  settings <- settingsFor file
  if tsDisabled settings
    then return []
    else do
      let unopt = if disableUnopt opts || tsDisableUnopt settings then [] else [False]
          opt   = if disableOpt opts || tsDisableOpt settings then [] else [True]
          runs  = unopt ++ opt
      concat <$> mapM (run settings) runs
    where
      run settings optimize = do
        output <- outputPath
        extra <- extraJsFiles file
        cd <- getWorkingDirectory
        let outputG2 = addExtension output "jsexe"
            outputRun = cd </> outputG2 </> ("all.js"::FilePath)
            input  = encodeString file
            desc = ", optimization: " ++ show optimize
            inc = includeOpt file
            compileOpts = if optimize
                            then [inc, "-o", encodeString output, "-O2"] ++ [input] ++ extra
                            else [inc, "-o", encodeString output] ++ [input] ++ extra
            args = tsArguments settings
        e <- liftIO $ runProcess "ghcjs" compileOpts ""
        case e of
          Nothing    -> assertFailure "cannot find ghcjs"
          Just (r,_) -> assertEqual "compile error" ExitSuccess (stdioExit r)
        forM_ (tsCopyFiles settings) $ \cfile ->
          let cfile' = fromText (TL.pack cfile)
          in  copyFile (directory file </> cfile') (cd </> outputG2 </> cfile')
        setWorkingDirectory (cd </> outputG2)
        nodeResult <-
          case tsDisableNode settings of
            False -> fmap (,"node" ++ desc) <$> runProcess "node" (encodeString outputRun:args) ""
            True  -> return Nothing
        smResult <-
          case tsDisableSpiderMonkey settings of
            False -> fmap (,"SpiderMonkey" ++ desc) <$> runProcess "js" (encodeString outputRun:args) ""
            True  -> return Nothing
        setWorkingDirectory cd
        liftIO $ removeTree outputG2
        return $ catMaybes [nodeResult, smResult]


outputPath :: IO FilePath
outputPath = do
  t <- show . round . (*1000) . utcTimeToPOSIXSeconds <$> getCurrentTime
  rnd <- show <$> randomRIO (1000000::Int,9999999)
  return . decodeString $ "ghcjs_test_" ++ t ++ "_" ++ rnd

-- | returns Nothing if the program cannot be run
runProcess :: MonadIO m => FilePath -> [String] -> String -> m (Maybe (StdioResult, Integer))
runProcess pgm args input = do
  before <- liftIO getCurrentTime
  (ex, out, err) <- liftIO $ readProcessWithExitCode (encodeString pgm) args input
  after <- liftIO getCurrentTime
  return $ 
    case ex of -- fixme is this the right way to find out that a program does not exist?
      (ExitFailure 127) -> Nothing
      _                 ->
        Just ( StdioResult ex (T.pack out) (T.pack err)
             , round $ 1000 * (after `diffUTCTime` before)
             )

{-
  a mocha test changes to the directory,
  runs the action, then runs `mocha'
  fails if mocha exits nonzero
 -}
mochaTest :: FilePath -> IO a -> IO b -> Test
mochaTest dir pre post = do
  undefined

writeFileT :: FilePath -> Text -> IO ()
writeFileT fp t = T.writeFile (encodeString fp) t

readFileT :: FilePath -> IO Text
readFileT fp = T.readFile (encodeString fp)

readExitCode :: Text -> Maybe ExitCode
readExitCode = fmap convert . readMaybe . T.unpack
  where
    convert 0 = ExitSuccess
    convert n = ExitFailure n

checkRequiredPackages :: IO ()
checkRequiredPackages = shelly . silently $ do
  installedPackages <- TL.words <$> run "ghcjs-pkg" ["list", "--simple-output"]
  forM_ requiredPackages $ \pkg -> do
    when (not $ any ((pkg <> "-") `TL.isPrefixOf`) installedPackages) $ do
      echo ("warning: package `" <> pkg <> "' is required by the test suite but is not installed")
--      liftIO exitFailure

getEnvMay :: String -> IO (Maybe String)
getEnvMay xs = fmap Just (getEnv xs)
               `Ex.catch` \(_::Ex.SomeException) -> return Nothing

getEnvOpt :: MonadIO m => String -> m Bool
getEnvOpt xs = liftIO (maybe False ((`notElem` ["0","no"]).map toLower) <$> getEnvMay xs)