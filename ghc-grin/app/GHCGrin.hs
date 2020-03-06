{-# LANGUAGE StandaloneDeriving, LambdaCase, OverloadedStrings #-}
module Main where

import Text.Printf
import Control.Monad

import System.Directory
import System.FilePath
import System.Environment
import System.Exit
import System.IO

import Stg.Syntax (ModuleName(..), UnitId(..))
import Stg.Util

import Lambda.GHCSymbols as GHCSymbols
import Lambda.FromStg
import Lambda.Syntax
import Lambda.Util
import Lambda.Pretty
import Lambda.Lint
import Lambda.Name
import Lambda.StaticSingleAssignment
import Lambda.DeadFunctionEliminationM
--import Pipeline.Pipeline

import Data.Maybe
import Data.List (foldl')
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BS8

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Binary
import qualified Crypto.Hash.BLAKE2.BLAKE2bp as BLAKE2

import Text.PrettyPrint.ANSI.Leijen (ondullblack, putDoc, plain, pretty, Doc, renderPretty, displayS)

import System.Posix.Resource

data Opts
  = Opts
  { inputs :: [FilePath]
  , output :: FilePath
  }

showUsage = do putStrLn "Usage: ghc-grin <stg-files> [-o <output-file>]"
               exitWith ExitSuccess

getOpts :: IO Opts
getOpts = do xs <- getArgs
             return $ process (Opts [] "a.out") xs
  where
    process opts ("-o":o:xs) = process (opts { output = o }) xs
    process opts (x:xs) = process (opts { inputs = x:inputs opts }) xs
    process opts [] = opts

deriving instance Show ResourceLimit
deriving instance Show ResourceLimits

collectImportedModules :: [FilePath] -> String -> String -> IO [FilePath]
collectImportedModules stgbinFileNames unitId mod = do
  -- filter dependenies only
  depList <- forM stgbinFileNames $ \fname -> do
    (_, u, m, deps) <- readDumpInfo fname
    pure ((u, m), [(du, dm) | (du, dl) <- deps, dm <- dl])
  let fnameMap  = Map.fromList $ zip (map fst depList) stgbinFileNames
      mnameMap  = Map.fromList $ zip stgbinFileNames (map fst depList)
      depMap    = Map.fromList depList
      calcDep s n
        | Set.member n s = s
        | Just l <- Map.lookup n depMap = foldl' calcDep (Set.insert n s) l
        | otherwise = Set.insert n s -- error $ printf "missing module: %s" . show $ getModuleName n

      keyMain = (UnitId $ BS8.pack unitId, ModuleName $ BS8.pack mod)
      prunedDeps = catMaybes [Map.lookup m fnameMap | m <- Set.toList $ foldl calcDep mempty $ keyMain : rtsDeps]
      rtsDeps = [(UnitId $ BS8.pack u, ModuleName $ BS8.pack m) | (u, m, _) <- catMaybes $ map (decodePackageQualifiedName . packName) GHCSymbols.liveSymbols]

  putStrLn $ "dependencies:\n" ++ unlines ["  " ++ (show $! mnameMap Map.! fname) | fname <- prunedDeps]

  pure prunedDeps

hashSize :: Int
hashSize = 64

type Hash = BS.ByteString

hashFile :: FilePath -> IO Hash
hashFile n = do
  BLAKE2.hash hashSize mempty <$> BS.readFile n

cache :: Hash -> FilePath -> (BS.ByteString -> IO a) -> (IO (a, BS.ByteString)) -> IO a
cache h1 n actionMatch actionNew = do
  eq <- doesFileExist n >>= \case
    False -> pure False
    True -> do
      f <- openFile n ReadMode
      h2 <- BS.hGet f hashSize
      hClose f
      pure $ h1 == h2
  case eq of
    True  -> BS.drop hashSize <$> BS.readFile n >>= actionMatch
    False -> do
      (new, newBin) <- actionNew
      BS.writeFile n $ h1 <> newBin
      pure new

toLambda :: String -> IO Program
toLambda fname = do
  h <- hashFile fname
  let lambdabinName = replaceExtension fname ".cache.lambdabin"

      load b = do
        printf "[cached] toLambda: %s\n" fname
        pure $ decode $ BSL.fromStrict b :: IO Program
        --decodeIO b

      new = do
        printf "toLambda: %s\n" fname
        stgModule <- readDump fname
        program <- codegenLambda stgModule

        let lambdaName = replaceExtension fname "lambda"
        writeFile lambdaName . showWidth 800 . plain $ pretty program

        pure (program, BSL.toStrict $ encode program)

  cache h lambdabinName load new

{-
replaceMain :: Program -> Program
replaceMain (Program exts cgroups sdata defs) = (Program exts cgroups sdata (mainFun : filter notMain defs)) where
  mainName = packName ":Main.main"
  notMain (Def n _ _) = n /= mainName
  mainFun = Def mainName [] $ App (packName "Main.main") [Lit $ LToken $ BS8.pack "GHC.Prim.void#"]
-}

addMain :: Program -> Program
addMain prg = prg { pDefinitions = mainFun : pDefinitions prg} where
  mainName = "main_::Main.main"
  mainFun = Def mainName [] $ LetS
    [ ("main_::Main.main_v00", SingleValue VoidRep, Lit $ LToken $ BS8.pack "ghc-prim_GHC.Prim.void#")
    , ("main_::Main.main_v01", SingleValue LiftedRep, App (packName "main_:Main.main") ["main_::Main.main_v00"])
    ] (Var "main_::Main.main_v01")

cg_main :: Opts -> IO ()
cg_main opts = do
  let inputLen = length $ inputs opts
  printf "input length: %d\n" inputLen
  r <- getResourceLimit ResourceOpenFiles
  print r
  let ResourceLimits (ResourceLimit minNum) (ResourceLimit maxNum) = r
  setResourceLimit ResourceOpenFiles $ ResourceLimits (ResourceLimit $ max minNum $ min (fromIntegral inputLen + minNum) maxNum) (ResourceLimit maxNum)

  prunedDeps <- collectImportedModules (inputs opts) "main" "Main"
  printf "pruned length: %d\n" $ length prunedDeps

  -- compile pruned program
  progList <- mapM toLambda prunedDeps
  putStrLn "finished toLambda"

  let wholeProgramBloat = addMain $ concatPrograms progList
  wholeProgram <- sortProgramDefs . singleStaticAssignment <$> deadFunctionEliminationM (["main_::Main.main", "main_:Main.main", "main_Main.main"] ++ GHCSymbols.liveSymbols) wholeProgramBloat
  let output_fn         = output opts
  writeFile (output_fn ++ ".lambda") . showWidth 800 . plain $ pretty wholeProgram
  lintLambda wholeProgram
  printf "all: %d pruned: %d\n" (length $ inputs opts) (length prunedDeps)
  let Program extsStripped  cgrouspStripped _ sdataStripped defsStripped  = wholeProgram
      Program extsBloat     cgroupsBloat    _ sdataBloat    defsBloat     = wholeProgramBloat
      conDefCount           = length [() | Def _ _ (Con{}) <- defsStripped]
  printf "bloat    lambda def count: %d\n" (length defsBloat)
  printf "stripped lambda def count: %d\n" (length defsStripped)
  printf "stripped lambda con def count: %d\n" conDefCount
  let histogram = programHistogram wholeProgram
  printf "program ast size: %d\n" $ sum [s * i | (s, (i,_)) <- Map.toList histogram]
  printf "def size histogram (size: count, sample def name)\n%s" $ unlines [printf "  % 7d: % 7d     %s" size count name | (size, (count, name)) <- Map.toList histogram]

  let pset = Set.fromList prunedDeps
      aset = Set.fromList $ inputs opts
  --printf "dead modules:\n%s" (unlines $ Set.toList $ aset Set.\\ pset)

  BS.writeFile (output_fn ++ ".lambdabin") . BSL.toStrict $ encode wholeProgram
  {-
  let lambdaGrin = codegenGrin wholeProgram
  writeFile (output_fn ++ ".grin") $ show $ plain $ pretty lambdaGrin
  -}

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  opts <- getOpts
  if (null (inputs opts))
     then showUsage
     else cg_main opts
{-
pipelineOpts :: PipelineOpts
pipelineOpts = defaultOpts
  { _poOutputDir = ".ghc-grin"
  , _poFailOnLint = True
  }
-}