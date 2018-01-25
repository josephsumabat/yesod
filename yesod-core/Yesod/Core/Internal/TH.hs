{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
module Yesod.Core.Internal.TH where

import Prelude hiding (exp)
import Yesod.Core.Handler

import Language.Haskell.TH hiding (cxt, instanceD)
import Language.Haskell.TH.Syntax

import qualified Network.Wai as W

import Data.ByteString.Lazy.Char8 ()
import Data.List (foldl')
#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>))
#endif
import Control.Monad (replicateM, void)
import Text.Parsec (parse, many1, many, eof, try, option, sepBy1)
import Text.ParserCombinators.Parsec.Char (alphaNum, spaces, string, char)

import Yesod.Routes.TH
import Yesod.Routes.Parse
import Yesod.Core.Types
import Yesod.Core.Content
import Yesod.Core.Class.Dispatch
import Yesod.Core.Internal.Run

-- | Generates URL datatype and site function for the given 'Resource's. This
-- is used for creating sites, /not/ subsites. See 'mkYesodSubData' and 'mkYesodSubDispatch' for the latter.
-- Use 'parseRoutes' to create the 'Resource's.
--
-- Contexts and type variables in the name of the datatype are parsed. 
-- For example, a datatype @App a@ with typeclass constraint @MyClass a@ can be written as @\"(MyClass a) => App a\"@.
mkYesod :: String -- ^ name of the argument datatype
        -> [ResourceTree String]
        -> Q [Dec]
mkYesod name = fmap (uncurry (++)) . mkYesodWithParser name False return

{-# DEPRECATED mkYesodWith "Contexts and type variables are now parsed from the name in `mkYesod`. <https://github.com/yesodweb/yesod/pull/1366>" #-}
-- | Similar to 'mkYesod', except contexts and type variables are not parsed. 
-- Instead, they are explicitly provided. 
-- You can write @(MyClass a) => App a@ with @mkYesodWith [[\"MyClass\",\"a\"]] \"App\" [\"a\"] ...@.
mkYesodWith :: [[String]] -- ^ list of contexts
            -> String -- ^ name of the argument datatype
            -> [String] -- ^ list of type variables
            -> [ResourceTree String]
            -> Q [Dec]
mkYesodWith cxts name args = fmap (uncurry (++)) . mkYesodGeneral cxts name args False return

-- | Sometimes, you will want to declare your routes in one file and define
-- your handlers elsewhere. For example, this is the only way to break up a
-- monolithic file into smaller parts. Use this function, paired with
-- 'mkYesodDispatch', to do just that.
mkYesodData :: String -> [ResourceTree String] -> Q [Dec]
mkYesodData name resS = fst <$> mkYesodWithParser name False return resS

mkYesodSubData :: String -> [ResourceTree String] -> Q [Dec]
mkYesodSubData name resS = fst <$> mkYesodWithParser name True return resS

-- | Parses contexts and type arguments out of name before generating TH.
mkYesodWithParser :: String                    -- ^ foundation type
                  -> Bool                      -- ^ is this a subsite
                  -> (Exp -> Q Exp)            -- ^ unwrap handler
                  -> [ResourceTree String]
                  -> Q([Dec],[Dec])
mkYesodWithParser name isSub f resS = do
    let (name', rest, cxt) = case parse parseName "" name of
            Left err -> error $ show err
            Right a -> a
    mkYesodGeneral cxt name' rest isSub f resS

    where
        parseName = do
            cxt <- option [] parseContext
            name' <- parseWord
            args <- many parseWord
            spaces
            eof
            return ( name', args, cxt)

        parseWord = do
            spaces
            many1 alphaNum

        parseContext = try $ do
            cxts <- parseParen parseContexts
            spaces
            _ <- string "=>"
            return cxts

        parseParen p = do
            spaces
            _ <- char '('
            r <- p
            spaces
            _ <- char ')'
            return r

        parseContexts = 
            sepBy1 (many1 parseWord) (spaces >> char ',' >> return ())

-- | See 'mkYesodData'.
mkYesodDispatch :: String -> [ResourceTree String] -> Q [Dec]
mkYesodDispatch name = fmap snd . mkYesodWithParser name False return

-- | Get the Handler and Widget type synonyms for the given site.
masterTypeSyns :: [Name] -> Type -> [Dec]
masterTypeSyns vs site =
    [ TySynD (mkName "Handler") (fmap PlainTV vs)
      $ ConT ''HandlerT `AppT` site `AppT` ConT ''IO
    , TySynD (mkName "Widget")  (fmap PlainTV vs)
      $ ConT ''WidgetT `AppT` site `AppT` ConT ''IO `AppT` ConT ''()
    ]

mkYesodGeneral :: [[String]]                -- ^ Appliction context. Used in RenderRoute, RouteAttrs, and ParseRoute instances.
               -> String                    -- ^ foundation type
               -> [String]                  -- ^ arguments for the type
               -> Bool                      -- ^ is this a subsite
               -> (Exp -> Q Exp)            -- ^ unwrap handler
               -> [ResourceTree String]
               -> Q([Dec],[Dec])
mkYesodGeneral appCxt' namestr mtys isSub f resS = do
    let appCxt = fmap (\(c:rest) -> 
#if MIN_VERSION_template_haskell(2,10,0)
            foldl' (\acc v -> acc `AppT` nameToType v) (ConT $ mkName c) rest
#else
            ClassP (mkName c) $ fmap nameToType rest
#endif
          ) appCxt'
    mname <- lookupTypeName namestr
    arity <- case mname of
               Just name -> do
                 info <- reify name
                 return $
                   case info of
                     TyConI dec ->
                       case dec of
#if MIN_VERSION_template_haskell(2,11,0)
                         DataD _ _ vs _ _ _ -> length vs
                         NewtypeD _ _ vs _ _ _ -> length vs
#else
                         DataD _ _ vs _ _ -> length vs
                         NewtypeD _ _ vs _ _ -> length vs
#endif
                         TySynD _ vs _ -> length vs
                         _ -> 0
                     _ -> 0
               _ -> return 0
    let name = mkName namestr
    -- Generate as many variable names as the arity indicates
    vns <- replicateM (arity - length mtys) $ newName "t"
        -- Base type (site type with variables)
    let argtypes = fmap nameToType mtys ++ fmap VarT vns
        site = foldl' AppT (ConT name) argtypes
        res = map (fmap (parseType . dropBracket)) resS
    renderRouteDec <- mkRenderRouteInstance appCxt site res
    routeAttrsDec  <- mkRouteAttrsInstance appCxt site res
    dispatchDec    <- mkDispatchInstance site appCxt f res
    parseRoute <- mkParseRouteInstance appCxt site res
    let rname = mkName $ "resources" ++ namestr
    eres <- lift resS
    let resourcesDec =
            [ SigD rname $ ListT `AppT` (ConT ''ResourceTree `AppT` ConT ''String)
            , FunD rname [Clause [] (NormalB eres) []]
            ]
    let dataDec = concat
            [ [parseRoute]
            , renderRouteDec
            , [routeAttrsDec]
            , resourcesDec
            , if isSub then [] else masterTypeSyns vns site
            ]
    return (dataDec, dispatchDec)

mkMDS :: (Exp -> Q Exp) -> Q Exp -> MkDispatchSettings a site b
mkMDS f rh = MkDispatchSettings
    { mdsRunHandler = rh
    , mdsSubDispatcher =
        [|\parentRunner getSub toParent env -> yesodSubDispatch
                                 YesodSubRunnerEnv
                                    { ysreParentRunner = parentRunner
                                    , ysreGetSub = getSub
                                    , ysreToParentRoute = toParent
                                    , ysreParentEnv = env
                                    }
                              |]
    , mdsGetPathInfo = [|W.pathInfo|]
    , mdsSetPathInfo = [|\p r -> r { W.pathInfo = p }|]
    , mdsMethod = [|W.requestMethod|]
    , mds404 = [|void notFound|]
    , mds405 = [|void badMethod|]
    , mdsGetHandler = defaultGetHandler
    , mdsUnwrapper = f
    }

-- | If the generation of @'YesodDispatch'@ instance require finer
-- control of the types, contexts etc. using this combinator. You will
-- hardly need this generality. However, in certain situations, like
-- when writing library/plugin for yesod, this combinator becomes
-- handy.
mkDispatchInstance :: Type                      -- ^ The master site type
                   -> Cxt                       -- ^ Context of the instance
                   -> (Exp -> Q Exp)            -- ^ Unwrap handler
                   -> [ResourceTree c]          -- ^ The resource
                   -> DecsQ
mkDispatchInstance master cxt f res = do
    clause' <- mkDispatchClause (mkMDS f [|yesodRunner|]) res
    let thisDispatch = FunD 'yesodDispatch [clause']
    return [instanceD cxt yDispatch [thisDispatch]]
  where
    yDispatch = ConT ''YesodDispatch `AppT` master

mkYesodSubDispatch :: [ResourceTree a] -> Q Exp
mkYesodSubDispatch res = do
    clause' <- mkDispatchClause (mkMDS return [|subHelper . fmap toTypedContent|]) res
    inner <- newName "inner"
    let innerFun = FunD inner [clause']
    helper <- newName "helper"
    let fun = FunD helper
                [ Clause
                    []
                    (NormalB $ VarE inner)
                    [innerFun]
                ]
    return $ LetE [fun] (VarE helper)

instanceD :: Cxt -> Type -> [Dec] -> Dec
#if MIN_VERSION_template_haskell(2,11,0)
instanceD = InstanceD Nothing
#else
instanceD = InstanceD
#endif
