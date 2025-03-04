-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE CPP               #-}
{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# OPTIONS -Wno-incomplete-uni-patterns -Wno-dodgy-imports #-}

-- | Attempt at hiding the GHC version differences we can.
module Development.IDE.GHC.Compat(
    NameCacheUpdater(..),
    hPutStringBuffer,
    addIncludePathsQuote,
    getModuleHash,
    setUpTypedHoles,
    upNameCache,
    disableWarningsAsErrors,
    reLoc,
    reLocA,
    getMessages',
    pattern PFailedWithErrorMessages,

#if !MIN_VERSION_ghc(9,0,1)
    RefMap,
#endif

#if MIN_VERSION_ghc(9,2,0)
    extendModSummaryNoDeps,
    emsModSummary,
#endif

    nodeInfo',
    getNodeIds,
    nodeInfoFromSource,
    isAnnotationInNodeInfo,
    mkAstNode,
    combineRealSrcSpans,

    isQualifiedImport,
    GhcVersion(..),
    ghcVersion,
    ghcVersionStr,
    -- * HIE Compat
    HieFileResult(..),
    HieFile(..),
    hieExportNames,
    mkHieFile',
    enrichHie,
    writeHieFile,
    readHieFile,
    supportsHieFiles,
    setHieDir,
    dontWriteHieFiles,
    module Compat.HieTypes,
    module Compat.HieUtils,
    -- * Compat modules
    module Development.IDE.GHC.Compat.Core,
    module Development.IDE.GHC.Compat.Env,
    module Development.IDE.GHC.Compat.ExactPrint,
    module Development.IDE.GHC.Compat.Iface,
    module Development.IDE.GHC.Compat.Logger,
    module Development.IDE.GHC.Compat.Outputable,
    module Development.IDE.GHC.Compat.Parser,
    module Development.IDE.GHC.Compat.Plugins,
    module Development.IDE.GHC.Compat.Units,
    -- * Extras that rely on compat modules
    -- * SysTools
    Option (..),
    runUnlit,
    runPp,
    ) where

import           Development.IDE.GHC.Compat.Core
import           Development.IDE.GHC.Compat.Env
import           Development.IDE.GHC.Compat.ExactPrint
import           Development.IDE.GHC.Compat.Iface
import           Development.IDE.GHC.Compat.Logger
import           Development.IDE.GHC.Compat.Outputable
import           Development.IDE.GHC.Compat.Parser
import           Development.IDE.GHC.Compat.Plugins
import           Development.IDE.GHC.Compat.Units
import           Development.IDE.GHC.Compat.Util
import           GHC                                   hiding (HasSrcSpan,
                                                        ModLocation,
                                                        RealSrcSpan, getLoc,
                                                        lookupName)

#if MIN_VERSION_ghc(9,0,0)
import           GHC.Data.StringBuffer
import           GHC.Driver.Session                    hiding (ExposePackage)
import qualified GHC.Types.SrcLoc                      as SrcLoc
import           GHC.Utils.Error
#if MIN_VERSION_ghc(9,2,0)
import           Data.Bifunctor
import           GHC.Driver.Env                        as Env
import           GHC.Unit.Module.ModIface
import           GHC.Unit.Module.ModSummary
#else
import           GHC.Driver.Types
#endif
import           GHC.Iface.Env
import           GHC.Iface.Make                        (mkIfaceExports)
import qualified GHC.SysTools.Tasks                    as SysTools
import qualified GHC.Types.Avail                       as Avail
#else
import qualified Avail
import           DynFlags                              hiding (ExposePackage)
import           HscTypes
import           MkIface                               hiding (writeIfaceFile)

#if MIN_VERSION_ghc(8,8,0)
import           StringBuffer                          (hPutStringBuffer)
#endif
import qualified SysTools

#if !MIN_VERSION_ghc(8,8,0)
import qualified EnumSet
import           SrcLoc                                (RealLocated)

import           Foreign.ForeignPtr
import           System.IO
#endif
#endif

import           Compat.HieAst                         (enrichHie)
import           Compat.HieBin
import           Compat.HieTypes
import           Compat.HieUtils
import qualified Data.ByteString                       as BS
import           Data.IORef

import           Data.List                             (foldl')
import qualified Data.Map                              as Map
import qualified Data.Set                              as Set

#if MIN_VERSION_ghc(9,0,0)
import qualified Data.Set                              as S
#endif

#if !MIN_VERSION_ghc(8,10,0)
import           Bag                                   (unitBag)
#endif

#if !MIN_VERSION_ghc(9,2,0)
reLoc :: Located a -> Located a
reLoc = id

reLocA :: Located a -> Located a
reLocA = id
#endif

#if !MIN_VERSION_ghc(8,8,0)
hPutStringBuffer :: Handle -> StringBuffer -> IO ()
hPutStringBuffer hdl (StringBuffer buf len cur)
    = withForeignPtr (plusForeignPtr buf cur) $ \ptr ->
             hPutBuf hdl ptr len
#endif

#if MIN_VERSION_ghc(9,2,0)
type ErrMsg  = MsgEnvelope DecoratedSDoc
#endif

getMessages' :: PState -> DynFlags -> (Bag WarnMsg, Bag ErrMsg)
getMessages' pst dflags =
#if MIN_VERSION_ghc(9,2,0)
                 bimap (fmap pprWarning) (fmap pprError) $
#endif
                 getMessages pst
#if !MIN_VERSION_ghc(9,2,0)
                   dflags
#endif

#if MIN_VERSION_ghc(9,2,0)
pattern PFailedWithErrorMessages :: forall a b. (b -> Bag (MsgEnvelope DecoratedSDoc)) -> ParseResult a
pattern PFailedWithErrorMessages msgs
     <- PFailed (const . fmap pprError . getErrorMessages -> msgs)
#elif MIN_VERSION_ghc(8,10,0)
pattern PFailedWithErrorMessages :: (DynFlags -> ErrorMessages) -> ParseResult a
pattern PFailedWithErrorMessages msgs
     <- PFailed (getErrorMessages -> msgs)
#else
pattern PFailedWithErrorMessages :: (DynFlags -> ErrorMessages) -> ParseResult a
pattern PFailedWithErrorMessages msgs
     <- ((fmap.fmap) unitBag . mkPlainErrMsgIfPFailed -> Just msgs)

mkPlainErrMsgIfPFailed (PFailed _ pst err) = Just (\dflags -> mkPlainErrMsg dflags pst err)
mkPlainErrMsgIfPFailed _ = Nothing
#endif
{-# COMPLETE PFailedWithErrorMessages #-}

supportsHieFiles :: Bool
supportsHieFiles = True

hieExportNames :: HieFile -> [(SrcSpan, Name)]
hieExportNames = nameListFromAvails . hie_exports


upNameCache :: IORef NameCache -> (NameCache -> (NameCache, c)) -> IO c
#if MIN_VERSION_ghc(8,8,0)
upNameCache = updNameCache
#else
upNameCache ref upd_fn
  = atomicModifyIORef' ref upd_fn
#endif

#if !MIN_VERSION_ghc(9,0,1)
type RefMap a = Map.Map Identifier [(Span, IdentifierDetails a)]
#endif

mkHieFile' :: ModSummary
           -> [Avail.AvailInfo]
           -> HieASTs Type
           -> BS.ByteString
           -> Hsc HieFile
mkHieFile' ms exports asts src = do
  let Just src_file = ml_hs_file $ ms_location ms
      (asts',arr) = compressTypes asts
  return $ HieFile
      { hie_hs_file = src_file
      , hie_module = ms_mod ms
      , hie_types = arr
      , hie_asts = asts'
      -- mkIfaceExports sorts the AvailInfos for stability
      , hie_exports = mkIfaceExports exports
      , hie_hs_src = src
      }

addIncludePathsQuote :: FilePath -> DynFlags -> DynFlags
addIncludePathsQuote path x = x{includePaths = f $ includePaths x}
    where f i = i{includePathsQuote = path : includePathsQuote i}

setHieDir :: FilePath -> DynFlags -> DynFlags
setHieDir _f d =
#if MIN_VERSION_ghc(8,8,0)
    d { hieDir     = Just _f}
#else
    d
#endif

dontWriteHieFiles :: DynFlags -> DynFlags
dontWriteHieFiles d =
#if MIN_VERSION_ghc(8,8,0)
    gopt_unset d Opt_WriteHie
#else
    d
#endif

setUpTypedHoles ::DynFlags -> DynFlags
setUpTypedHoles df
  = flip gopt_unset Opt_AbstractRefHoleFits    -- too spammy
#if MIN_VERSION_ghc(8,8,0)
  $ flip gopt_unset Opt_ShowDocsOfHoleFits     -- not used
#endif
  $ flip gopt_unset Opt_ShowMatchesOfHoleFits  -- nice but broken (forgets module qualifiers)
  $ flip gopt_unset Opt_ShowProvOfHoleFits     -- not used
  $ flip gopt_unset Opt_ShowTypeAppOfHoleFits  -- not used
  $ flip gopt_unset Opt_ShowTypeAppVarsOfHoleFits -- not used
  $ flip gopt_unset Opt_ShowTypeOfHoleFits     -- massively simplifies parsing
  $ flip gopt_set   Opt_SortBySubsumHoleFits   -- very nice and fast enough in most cases
  $ flip gopt_unset Opt_SortValidHoleFits
  $ flip gopt_unset Opt_UnclutterValidHoleFits
  $ df
  { refLevelHoleFits = Just 1   -- becomes slow at higher levels
  , maxRefHoleFits   = Just 10  -- quantity does not impact speed
  , maxValidHoleFits = Nothing  -- quantity does not impact speed
  }


nameListFromAvails :: [Avail.AvailInfo] -> [(SrcSpan, Name)]
nameListFromAvails as =
  map (\n -> (nameSrcSpan n, n)) (concatMap Avail.availNames as)


getModuleHash :: ModIface -> Fingerprint
#if MIN_VERSION_ghc(8,10,0)
getModuleHash = mi_mod_hash . mi_final_exts
#else
getModuleHash = mi_mod_hash
#endif


disableWarningsAsErrors :: DynFlags -> DynFlags
disableWarningsAsErrors df =
    flip gopt_unset Opt_WarnIsError $ foldl' wopt_unset_fatal df [toEnum 0 ..]

#if !MIN_VERSION_ghc(8,8,0)
wopt_unset_fatal :: DynFlags -> WarningFlag -> DynFlags
wopt_unset_fatal dfs f
    = dfs { fatalWarningFlags = EnumSet.delete f (fatalWarningFlags dfs) }
#endif

isQualifiedImport :: ImportDecl a -> Bool
#if MIN_VERSION_ghc(8,10,0)
isQualifiedImport ImportDecl{ideclQualified = NotQualified} = False
isQualifiedImport ImportDecl{}                              = True
#else
isQualifiedImport ImportDecl{ideclQualified}                = ideclQualified
#endif
isQualifiedImport _                                         = False



#if MIN_VERSION_ghc(9,0,0)
getNodeIds :: HieAST a -> Map.Map Identifier (IdentifierDetails a)
getNodeIds = Map.foldl' combineNodeIds Map.empty . getSourcedNodeInfo . sourcedNodeInfo

combineNodeIds :: Map.Map Identifier (IdentifierDetails a)
                        -> NodeInfo a -> Map.Map Identifier (IdentifierDetails a)
ad `combineNodeIds` (NodeInfo _ _ bd) = Map.unionWith (<>) ad bd

--  Copied from GHC and adjusted to accept TypeIndex instead of Type
-- nodeInfo' :: Ord a => HieAST a -> NodeInfo a
nodeInfo' :: HieAST TypeIndex -> NodeInfo TypeIndex
nodeInfo' = Map.foldl' combineNodeInfo' emptyNodeInfo . getSourcedNodeInfo . sourcedNodeInfo

combineNodeInfo' :: Ord a => NodeInfo a -> NodeInfo a -> NodeInfo a
(NodeInfo as ai ad) `combineNodeInfo'` (NodeInfo bs bi bd) =
  NodeInfo (S.union as bs) (mergeSorted ai bi) (Map.unionWith (<>) ad bd)
  where
    mergeSorted :: Ord a => [a] -> [a] -> [a]
    mergeSorted la@(a:as) lb@(b:bs) = case compare a b of
                                        LT -> a : mergeSorted as lb
                                        EQ -> a : mergeSorted as bs
                                        GT -> b : mergeSorted la bs
    mergeSorted as [] = as
    mergeSorted [] bs = bs

#else

getNodeIds :: HieAST a -> NodeIdentifiers a
getNodeIds = nodeIdentifiers . nodeInfo
-- import qualified FastString as FS

-- nodeInfo' :: HieAST TypeIndex -> NodeInfo TypeIndex
nodeInfo' :: Ord a => HieAST a -> NodeInfo a
nodeInfo' = nodeInfo
-- type Unit = UnitId
-- moduleUnit :: Module -> Unit
-- moduleUnit = moduleUnitId
-- unhelpfulSpanFS :: FS.FastString -> FS.FastString
-- unhelpfulSpanFS = id
#endif

nodeInfoFromSource :: HieAST a -> Maybe (NodeInfo a)
#if MIN_VERSION_ghc(9,0,0)
nodeInfoFromSource = Map.lookup SourceInfo . getSourcedNodeInfo . sourcedNodeInfo
#else
nodeInfoFromSource = Just . nodeInfo
#endif

data GhcVersion
  = GHC86
  | GHC88
  | GHC810
  | GHC90
  | GHC92
  deriving (Eq, Ord, Show)

ghcVersionStr :: String
ghcVersionStr = VERSION_ghc

ghcVersion :: GhcVersion
#if MIN_VERSION_GLASGOW_HASKELL(9,2,0,0)
ghcVersion = GHC92
#elif MIN_VERSION_GLASGOW_HASKELL(9,0,0,0)
ghcVersion = GHC90
#elif MIN_VERSION_GLASGOW_HASKELL(8,10,0,0)
ghcVersion = GHC810
#elif MIN_VERSION_GLASGOW_HASKELL(8,8,0,0)
ghcVersion = GHC88
#elif MIN_VERSION_GLASGOW_HASKELL(8,6,0,0)
ghcVersion = GHC86
#endif

runUnlit :: Logger -> DynFlags -> [Option] -> IO ()
runUnlit =
#if MIN_VERSION_ghc(9,2,0)
    SysTools.runUnlit
#else
    const SysTools.runUnlit
#endif

runPp :: Logger -> DynFlags -> [Option] -> IO ()
runPp =
#if MIN_VERSION_ghc(9,2,0)
    SysTools.runPp
#else
    const SysTools.runPp
#endif

isAnnotationInNodeInfo :: (FastString, FastString) -> NodeInfo a -> Bool
#if MIN_VERSION_ghc(9,2,0)
isAnnotationInNodeInfo (ctor, typ) = Set.member (NodeAnnotation ctor typ) . nodeAnnotations
#else
isAnnotationInNodeInfo p = Set.member p . nodeAnnotations
#endif

mkAstNode :: NodeInfo a -> Span -> [HieAST a] -> HieAST a
#if MIN_VERSION_ghc(9,0,0)
mkAstNode n = Node (SourcedNodeInfo $ Map.singleton GeneratedInfo n)
#else
mkAstNode = Node
#endif

combineRealSrcSpans :: RealSrcSpan -> RealSrcSpan -> RealSrcSpan
#if MIN_VERSION_ghc(9,2,0)
combineRealSrcSpans = SrcLoc.combineRealSrcSpans
#else
combineRealSrcSpans span1 span2
  = mkRealSrcSpan (mkRealSrcLoc file line_start col_start) (mkRealSrcLoc file line_end col_end)
  where
    (line_start, col_start) = min (srcSpanStartLine span1, srcSpanStartCol span1)
                                  (srcSpanStartLine span2, srcSpanStartCol span2)
    (line_end, col_end)     = max (srcSpanEndLine span1, srcSpanEndCol span1)
                                  (srcSpanEndLine span2, srcSpanEndCol span2)
    file = srcSpanFile span1
#endif
