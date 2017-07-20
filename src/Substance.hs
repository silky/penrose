-- module Substance where
module Main (main) where -- for debugging purposes
-- TODO split this up + do selective export

import Utils
import Control.Monad (void)
import System.IO -- read/write to file
import System.Environment
import Control.Arrow ((>>>))
import System.Random
import Debug.Trace
import Data.List
import Data.Maybe (fromMaybe)
import Text.Megaparsec
import Text.Megaparsec.Expr
import Text.Megaparsec.String -- input stream is of the type ‘String’
-- import Text.PrettyPrint
import Text.PrettyPrint.HughesPJClass hiding (colon, comma, parens, braces)
import qualified Data.Map.Strict as M
import qualified Text.Megaparsec.Lexer as L

--------------------------------------------------------------------------------
-- Substance AST

-- | A Substance program is a list of statements
type SubProg = [SubStmt]
type SubObjDiv = ([SubDecl], [SubConstr])

-- | A statement can either be a declaration of some mathematical object, or a
--   definition (used by Alloy)
data SubStmt
    = Decl SubType String -- type, id
    | DeclList SubType [String] -- Allowing comma separated declarations
    | ConstrDecl SubType [String] -- type, arguments
    | SetInit SubType String [String]
    | MapInit SubType String String String -- id, from, to
    | FuncVal String String String -- function name, x, y
    | Def String [(SubType, String)] FOLExpr -- id, definition string
    | DefApp String [String] -- function id, args
    | NoStmt
    deriving (Show, Eq)

-- data Prop = Prop Term deriving (Show, Eq)
data FOLExpr
    = QuantAssign Quant Binders FOLExpr
    | BinaryOp Op FOLExpr FOLExpr
    | FuncAccess String String
    | TermID String
    deriving (Show, Eq)
data Op = AND | OR | NOT | IMPLIES | EQUAL | NEQ deriving (Show, Eq)
data Quant = FORALL | EXISTS deriving (Show, Eq)
type Binders = [(String, String)]

data SubType
    = SetT
    | PointT
    | MapT
    | IntersectT
    | NoIntersectT
    | NoSubsetT
    | SubsetT
    | PointInT
    | PointNotInT
    | ValueT
    | AllT  -- specifically for global selection in Style
    | DerivedType SubType -- TODO: inheritance of types? Openset
    deriving (Show, Eq)

data SubObj = LD SubDecl | LC SubConstr deriving (Show, Eq)

data SubDecl
    = Set String
    | Map String String String
    | Value String String String
    | Point String
    deriving (Show, Eq)

data SubConstr
    = Intersect String String
    | NoIntersect String String
    | Subset String String
    | NoSubset String String
    | PointIn String String
    | PointNotIn String String
    deriving (Show, Eq)

-- objTypes = [ SetT, PointT, MapT ]
-- constrTypes = [ IntersectT, NoIntersectT, NoSubsetT, SubsetT, PointInT,
--                 PointNotInT, FuncValT ]

--------------------------------------------------------------------------------
-- Parser for Substance

substanceParser :: Parser [SubStmt]
substanceParser = between sc eof subProg

subProg :: Parser [SubStmt]
subProg =  endBy subStmt newline'

subStmt :: Parser SubStmt
subStmt = try subDef <|> subDecl <|> defApp

subDecl, varDecl, setInit, funcDecl :: Parser SubStmt
-- TODO: think about why the `try` is needed here?
subDecl = try setInit <|> try funcVal <|>  try varDecl <|> try constrDecl <|> try funcDecl
constrDecl = do
    -- a <- identifier
    typ <- subConstrType
    -- b <- identifier
    args <- someTill (try  identifier) newline
    return (ConstrDecl typ args)
    -- return (ConstrDecl typ [a, b])
varDecl = do
    typ <- subObjType
    ids <- identifier `sepBy1` comma
    if length ids == 1
        then return (Decl typ (head ids))
        else return (DeclList typ ids)
setInit = do
    rword "Set"
    i <- identifier
    void (symbol "=")
    ids <- braces $ identifier `sepBy1` comma
    return (SetInit SetT i ids)
funcDecl = do
    i <- identifier
    colon
    a <- identifier
    arrow
    b <- identifier
    return (MapInit MapT i a b)
funcVal = do
    f <- some alphaNumChar
    a <- parens identifier
    void (symbol "=")
    b <- identifier
    return (FuncVal f a b)

subDef :: Parser SubStmt
subDef = do
    rword "Definition"
    i    <- identifier
    args <- parens $ bindings `sepBy1` comma
    colon >> newline'
    t     <- folExpr
    -- str <- some printChar
    -- return (Def i str)
    return (Def i args t)
    where bindings = (,) <$> subtype <*> identifier

defApp :: Parser SubStmt
defApp = do
    n <- identifier
    args <- parens $ identifier `sepBy1` comma
    return (DefApp n args)

folExpr :: Parser FOLExpr
folExpr = makeExprParser folTerm folOps

folOps :: [[Operator Parser FOLExpr]]
folOps =
    [ [ InfixL (BinaryOp EQUAL   <$ symbol "=")
      , InfixL (BinaryOp NEQ     <$ symbol "!=") ]
    , [ InfixL (BinaryOp AND     <$ symbol "/\\") ]
    , [ InfixR (BinaryOp IMPLIES <$ symbol "implies" )]
    , [ InfixL (BinaryOp OR      <$ symbol "\\/") ]
    ]

folTerm = try quantAssign <|> try funcAccess <|> TermID <$> try identifier

quantAssign, funcAccess :: Parser FOLExpr
quantAssign = do
    q <- quant
    bs <- binders
    void (symbol "|")
    e <- folExpr
    return (QuantAssign q bs e)
    -- return (QuantAssign q bs (TermID "ja"))
funcAccess = do
    t1 <- identifier
    t2 <- parens identifier
    return (FuncAccess t1 t2)

binders :: Parser Binders
binders = binder `sepBy1` comma
    where binder = (,) <$> identifier <* colon <*> identifier
quant = (symbol "forall" >> return FORALL) <|>
        (symbol "exists" >> return EXISTS)

subtype :: Parser SubType
subtype = subObjType <|> subConstrType
subObjType =
        (rword "Set"         >> return SetT)               <|>
        -- (rword "OpenSet"     >> return (DerivedType SetT)) <|>
        (rword "Point"       >> return PointT)             <|>
        (rword "Map"         >> return MapT)               <|>
        (rword "Value"       >> return ValueT)
subConstrType =
        (rword "Subset"      >> return SubsetT)      <|>
        (rword "NoSubset"    >> return NoSubsetT)    <|>
        (rword "Intersect"   >> return IntersectT)   <|>
        (rword "NoIntersect" >> return NoIntersectT) <|>
        (rword "In"          >> return PointInT)     <|>
        (rword "NotIn"       >> return PointNotInT)

--------------------------------------------------------------------------------
-- Semantic checker and desugaring

data SubEnv = SubEnv {
    subObjs :: [SubObj],
    subDefs :: M.Map String ([(SubType, String)], FOLExpr),
    subApps :: [(FOLExpr, M.Map String String)],
    subSymbols :: M.Map String SubType
    -- subAppliedDefs :: [FOLExpr]
} deriving (Show, Eq)

-- The check is done in two passes. First check all the declarations of
-- stand-alone objects like `Set`, and then check for all other things
check :: SubProg -> SubEnv
check p = let env1 = foldl checkDecls initE p
              env2 = foldl checkReferencess env1 p
            --   defs = applyDefs env2
              in
            --   (os, ds, m) = foldl checkReferencess env1 p in
            env2 { subObjs = reverse $ subObjs env2
                    -- , subAppliedDefs = defs
                }
        --   (reverse os, ds, m) -- TODO: to make sure of the ordering of objects
          where initE = SubEnv { subObjs = [], subDefs = M.empty,  subSymbols = M.empty, subApps = [] }

applyDef (n, m) d = case M.lookup n d of
    Nothing -> error "applyDef: definition not found!"
    Just (_, e) -> e

        -- where checkDecls' e s = if s `elem` declStmtT then

checkDecls :: SubEnv -> SubStmt -> SubEnv
checkDecls e (Decl t s)  = e { subObjs = toObj t [s] : subObjs e, subSymbols = checkAndInsert s t $ subSymbols e }
checkDecls e (DeclList t ss) = e { subObjs = objs, subSymbols = syms }
    where objs = subObjs e ++ map (toObj t . toList) ss
          syms = foldl (\p x -> checkAndInsert x t p) (subSymbols e) ss
checkDecls e (MapInit t f a b) =
    e { subSymbols = checkAndInsert f t $ subSymbols e }
checkDecls e (Def n a f) = e { subDefs = M.insert n (a, f) $ subDefs e }
checkDecls e (SetInit t i ps) =
    let pts =  map (toObj PointT . toList) ps
        set = toObj t [i]
        ptConstrs = map (toConstr PointInT . (\p -> [p, i])) ps
        m1  = foldl (\p x -> checkAndInsert x PointT p) (subSymbols e) ps
    in
    e { subObjs = pts ++ [set] ++ ptConstrs ++ subObjs e, subSymbols = checkAndInsert i t m1 }
-- checkDecls (os, ds, m) (Decl t s)  = (toObj t [s] : os, ds, checkAndInsert s t m)
-- checkDecls (os, ds, m) (DeclList t ss) =
--     (os ++ map (toObj t . toList) ss, ds, foldl (\p x -> checkAndInsert x t p) m ss)
-- checkDecls (os, ds, m) (MapInit t f a b) =
--     (os, ds, checkAndInsert f t m)
-- TODO: assuming we ONLY have set of **points**
-- FIXME: snd of the tuple is wrong, change to map
-- checkDecls (os, ds, m) (Def n a f) = (os, (f, M.empty) : ds, m)
-- checkDecls (os, ds, m) (SetInit t i ps) =
--     let pts =  map (toObj PointT . toList) ps
--         set = toObj t [i]
--         ptConstrs = map (toConstr PointInT . (\p -> [p, i])) ps
--         m1  = foldl (\p x -> checkAndInsert x PointT p) m ps
--     in
--     ( pts ++ [set] ++ ptConstrs ++ os, ds, checkAndInsert i t m1)
    -- TODO: making the assumption that users want the points to be on top of sets
checkDecls e _ = e -- Ignore all other statements

toObj :: SubType -> [String] -> SubObj
toObj SetT [i]         = LD $ Set i
toObj PointT [i]       = LD $ Point i
toObj MapT [i, a, b]   = LD $ Map i a b
toObj ValueT [f, a, b] = LD $ Value f a b
toObj t os             = error ("toObj: incorrect arguments to " ++ show t ++ " "++ show os)

checkReferencess :: SubEnv -> SubStmt -> SubEnv
checkReferencess e (ConstrDecl t ss)  = e { subObjs = newConstrs : subObjs e }
    where newConstrs = toConstr t $ map (checkNameAndTyp $ subSymbols e) $ zip ss ts
          ts = case t of
              PointInT    -> [PointT, SetT]
              PointNotInT -> [PointT, SetT]
              _           -> [SetT, SetT]
checkReferencess e (FuncVal f a b)  = e { subObjs = val : subObjs e }
    where args = map (checkNameAndTyp $ subSymbols e) $ zip [f, a, b] [MapT, PointT, PointT]
          val  = toObj ValueT args
checkReferencess e (MapInit t f a b) = e { subObjs = toObj t args : subObjs e }
    where args = map (checkNameAndTyp $ subSymbols e) $ zip [f, a, b] [MapT, SetT, SetT]
checkReferencess e (DefApp n args) = e { subApps = (def, apps) : subApps e }
    where (sigs, def)  = fromMaybe (error ("Definition " ++ n ++ " does not exist.")) (M.lookup n (subDefs e))
          args' = map (checkNameAndTyp $ subSymbols e) $ zip args $ map fst sigs
          apps  = M.fromList $ zip (map snd sigs) args

-- TODO
-- checkAndApplyDef :: FOLExpr -> M.Map String String -> FOLExpr
-- checkAndApplyDef (QuantAssign q b e) m = (q, b', e')
--     where b' =
-- checkBinding (_, n) m =
-- lookupVarMap e

-- data FOLExpr
--     = QuantAssign Quant Binders FOLExpr
--     | BinaryOp Op FOLExpr FOLExpr
--     | FuncAccess String String
--     | TermID String
--     deriving (Show, Eq)

checkReferencess e _ = e -- Ignore all other statements


-- checkReferencess (os, ds, m) (ConstrDecl t ss)  = (newConstrs : os, ds, m)
--     where newConstrs = toConstr t $ map (checkNameAndTyp m) $ zip ss ts
--           ts = case t of
--               PointInT    -> [PointT, SetT]
--               PointNotInT -> [PointT, SetT]
--               _           -> [SetT, SetT]
-- checkReferencess (os, ds, m) (FuncVal f a b)  = (val : os, ds, m)
--     where args = map (checkNameAndTyp m) $ zip [f, a, b] [MapT, PointT, PointT]
--           val  = toObj ValueT args
-- checkReferencess (os, ds, m) (MapInit t f a b) = (toObj t args : os, ds, m)
--     where args = map (checkNameAndTyp m) $ zip [f, a, b] [MapT, SetT, SetT]
-- -- checkReferencess (os, ds, m) (DefApp n args) =
--     -- where insertMap = case M.lookup

toConstr NoIntersectT [a, b] = LC $ NoIntersect a b
toConstr IntersectT [a, b] = LC $ Intersect a b
toConstr PointInT [a, b] = LC $ PointIn a b
toConstr PointNotInT [a, b] = LC $ PointNotIn a b
toConstr SubsetT [a, b] = LC $ Subset a b
toConstr NoSubsetT [a, b] = LC $ NoSubset a b
toConstr t os = error ("toConstr: incorrect arguments to " ++ show t ++ " "++ show os)

checkAndInsert s t m = case M.lookup s m of
    Nothing -> M.insert s t m
    _ -> error ("Duplicated symbol: " ++ s)
checkNameAndTyp m (s, t) = case M.lookup s m of
    Nothing -> error ("Undefined symbol: " ++ s)
    Just t' -> if t == t' then s
            else error ("Type of " ++ s ++ " is incorrect. Expecting " ++ show t ++ " , but have " ++ show t')

subSeparate :: [SubObj] -> SubObjDiv
subSeparate = foldr separate ([], [])
            where separate line (decls, constrs) =
                           case line of
                           (LD x) -> (x : decls, constrs)
                           (LC x) -> (decls, x : constrs)

--------------------------------------------------------------------------------
-- Simplified Alloy AST and translators
-- See reference for the Alloy modeling language here:
--  http://alloy.mit.edu/alloy/documentation/book-chapters/alloy-language-reference.pdf
-- TODO: separate to another module?


-- | each Alloy program is a collection of paragraphs
type AlProg = [AlPara]
data AlPara
    = SigDecl String [AlDecl]
    | OneSigDecl String String
    | PredDecl String
    | FactDecl [AlExpr]
    | RunCmd String (Maybe Int)
    deriving (Show, Eq)
-- NOTE: this is okay if we model everything as the same type of relations
data AlDecl = AlDecl String String
    deriving (Show, Eq)
data AlExpr
    = AlFuncVal String String String
    | AlProp FOLExpr (M.Map String String)
    deriving (Show, Eq)
    -- = AlFuncVal String String String
    -- | AlDef String
data AlBinaryOp = AlDot | AlEq deriving (Show, Eq)

-- | Substance to Alloy translation environment:
data AlEnv = AlEnv {
    alFacts :: [AlExpr],
    alSigs  :: M.Map String AlPara
} deriving (Show, Eq)

-- | translating a Substance program to an Alloy program
toAlloy :: SubEnv -> AlProg
toAlloy e =  M.elems (alSigs resEnv) ++ rest
    where initEnv = AlEnv { alFacts = [], alSigs = M.empty }
          objEnv  = foldl objToAlloy initEnv $ subObjs e
          resEnv  = foldl defToAlloy objEnv $ subApps e
          rest = [FactDecl (alFacts resEnv), showPred, runNoLimit "show"]

-- | default components in an Alloy program, for showing instances
showPred = PredDecl "show"
runNoLimit s = RunCmd s Nothing

objToAlloy :: AlEnv -> SubObj -> AlEnv
objToAlloy e (LD (Set s)) = e { alSigs = insertSig s (SigDecl s []) $ alSigs e}
objToAlloy e (LC (PointIn p s)) = e { alSigs = M.insert p (OneSigDecl p s) $ alSigs e }
objToAlloy e (LD (Value f x y)) = e { alFacts = fac : alFacts e }
    where  fac = AlFuncVal f x y
        -- fac = AlBinOp AlEq (AlBinOp AlDot x f) y
objToAlloy e (LD (Map f x y)) = e { alSigs = newSigs }
    where  l' = AlDecl f y : l
           newSigs = M.insert x (SigDecl n l') m
           (SigDecl n l, m) = case M.lookup x $ alSigs e of
                Nothing -> let sig = SigDecl x [] in (sig, M.insert x sig $ alSigs e)
                Just s -> (s, alSigs e)
objToAlloy e _ = e -- Ignoring all other Substance objects

-- To make sure the ordering doesn't matter. For example, if we have a Function
-- declared before the sets, the translator will generate the signatures
insertSig n s e = case M.lookup n e of
    Nothing -> M.insert n s e
    _ -> e

defToAlloy :: AlEnv -> (FOLExpr, M.Map String String) -> AlEnv
defToAlloy e (f, m) =  e { alFacts = AlProp f m : alFacts e }

-- | pretty-printing class for Alloy AST
-- instance P.Pretty AlProg where
--     pPrint p = map pPrint p
instance Pretty AlPara where
    pPrint (SigDecl n ds) = vcat (header : map (nest 4 . pPrint) ds) $$ rbrace
        where header = text "sig" <+> text n <+> lbrace
    pPrint (OneSigDecl s e) = text "one sig" <+> text s <+> text "extends" <+> text e <> lbrace <+> rbrace
    pPrint (PredDecl s) = text "pred" <+> text (s ++ "()") <+> lbrace <+> rbrace
    pPrint (FactDecl es) = vcat (header : map (nest 2 . pPrint) es) $$ rbrace
        where header =  text "fact" <+> lbrace
    pPrint (RunCmd s i) = text "run" <+> text s <+> num
        where num = case i of
                        Nothing -> text ""
                        Just i' -> text (show i')
instance Pretty AlDecl where
    pPrint (AlDecl f s) = text f <+> text ":" <+> text s
instance Pretty AlExpr where
    pPrint (AlFuncVal f x y) = text x <> text "." <> text f <+> text "=" <+> text y
    pPrint (AlProp s varMap) = pPrintExpr s varMap

pPrintExpr :: FOLExpr -> M.Map String String -> Doc
pPrintExpr s varMap = case s of
    QuantAssign q b e -> pPrint q <+> hcat (map (pBind . bind varMap) b) <+> text "|" <+> pPrintExpr e varMap
    BinaryOp op e1 e2 -> pPrintExpr e1 varMap <+> pPrint op <+> pPrintExpr e2 varMap
    FuncAccess f x -> text x <> text "." <> text f
    TermID i -> text i
    where bind m (a, s) = case M.lookup s m of
                             Nothing -> error ("Undefined variable: " ++ s)
                             Just s' -> (a, s')
          pBind (a, b) = text a <+> text ":" <+> text b

instance Pretty Quant where
    pPrint FORALL = text "all"
    pPrint EXISTS = text "some"

instance Pretty Op where
    pPrint IMPLIES = text "implies"
    pPrint EQUAL   = text "="

--------------------------------------------------------------------------------
-- Old Substance AST

-- type SubSpec = [SubLine]
-- type SubSpecDiv = ([SubDecl], [SubConstr])
--
-- data SubLine
--     = LD SubDecl
--     | LC SubConstr
--      deriving (Show, Eq)
--
-- data SetType = Open | Closed | Unspecified
--      deriving (Show, Eq)
--
-- data Set = Set' String SetType
--      deriving (Show, Eq)
--
-- data Pt = Pt' String
--      deriving (Show, Eq)
--
-- -- Map <label> <from-set> <to-set>
-- data Map = Map' String String String -- TODO needs validation vs Set Set
--      deriving (Show, Eq)
--
-- data SubObj = OS Set | OP Pt | OM Map
--      deriving (Show, Eq)
--
-- data SubObjType = Set SetType | Pt | Map -- how to tie this to the types above
--      deriving (Show, Eq)
--
-- data SubDecl = Decl SubObj
--      deriving (Show, Eq)
--
-- -- TODO vs. Set Set. user only specifies names
-- -- TODO we assume that non-subset sets must not overlap (implicit constraint)
-- data SubConstr = Intersect String String
--                | NoIntersect String String
--                | Subset String String
--                | NoSubset String String
--                | PointIn String String
--                | PointNotIn String String
--      deriving (Show, Eq)
--
--
--  --------------------------------------------------------------------------------
-- -- Old Substance parser
-- -- TODO divide into decls and constraints for typechecking and reference checking
-- -- parsing human-written programs: extra spaces ok (words removes them).
-- -- extra newlines ok (filter empty lines out). HOWEVER, this is not ok for validation, as
-- -- the pretty-printer does not add additional whitespace.
-- subParse :: String -> SubSpec
-- subParse = map (subToLine . words) . filter nonempty . lines
--          where nonempty x = (x /= "")
--
-- -- parses based on line length. should really tokenize and behave like DFA
-- -- TODO fix this or use lexer / parser generator
-- subToLine :: [String] -> SubLine
-- subToLine s@[x, y] = LD $ Decl $
--                   if x == "Set" then OS (Set' y Unspecified)
--                   else if x == "OpenSet" then OS (Set' y Open)
--                   else if x == "ClosedSet" then OS (Set' y Closed)
--                   else if x == "Point" then OP (Pt' y)
--                   else error $ "Substance spec line: 2-token line '"
--                        ++ show s ++ "' does not begin with Set/OpenSet/ClosedSet"
--
-- -- TODO validate names exist in decls, are of type set
-- -- TODO auto-gen parser from grammar
-- subToLine s@[x, y, z] = LC $
--                    if x == "Intersect" then Intersect y z
--                    else if x == "NoIntersect" then NoIntersect y z
--                    else if x == "Subset" then Subset y z
--                    else if x == "NoSubset" then NoSubset y z
--                    else if x == "In" then PointIn y z -- TODO ^
--                    else if x == "NotIn" then PointNotIn y z
--                    else error $ "Substance spec line: 3-token line '"
--                      ++ show s ++ "' does not begin with (No)Intersect/Subset/(Not)In"
--
-- subToLine s@[w, x, y, z] = LD $ Decl $
--                    if w == "Map" then OM (Map' x y z)
--                    else error $ "Substance spec line: 4-token line '"
--                        ++ show s ++ "' does not begin with Map"
--
-- subToLine s = error $ "Substance spec line '" ++ show s ++ "' is not 2, 3, or 4 tokens"
--
-- -- Pretty-printer for Substance AST
-- subPrettyPrintLine :: SubLine -> String
-- subPrettyPrintLine (LD (Decl decl)) = case decl of
--                    OS (Set' name stype) -> case stype of
--                                           Open -> "OpenSet " ++ name
--                                           Closed -> "ClosedSet " ++ name
--                                           Unspecified -> "Set " ++ name
--                    OP (Pt' name) -> "Point " ++ name
--                    OM (Map' x y z) -> "Map " ++ x ++ " " ++ y ++ " " ++ z
-- subPrettyPrintLine (LC constr) = case constr of
--                      Subset s1 s2   -> "Subset " ++ s1 ++ " " ++ s2
--                      PointIn p s    -> "In " ++ p ++ " " ++ s
--                      PointNotIn p s -> "NotIn " ++ p ++ " " ++ s
--
-- subPrettyPrint :: SubSpec -> String
-- subPrettyPrint s = concat $ intersperse nl $ map subPrettyPrintLine s
--
-- -- Ugly pretty-printer for Substance
-- subPrettyPrintLine' :: SubLine -> String
-- subPrettyPrintLine' = show
--
-- subPrettyPrint' :: SubSpec -> String
-- subPrettyPrint' s = concat $ intersperse nl $ map subPrettyPrintLine' s
--
-- -- if a well-formed program is parsed, its output should equal the original
-- subValidate :: String -> Bool
-- subValidate s = (s == (subPrettyPrint $ subParse s))
--
-- subValidateAll :: [String] -> Bool
-- subValidateAll = all subValidate
--
-- -- Substance reference checker TODO
-- -- returns lines in same order as in program
-- subSeparate :: SubSpec -> SubSpecDiv
-- subSeparate = foldr separate ([], [])
--             where separate line (decls, constrs) =
--                            case line of
--                            (LD x) -> (x : decls, constrs)
--                            (LC x) -> (decls, x : constrs)
--
-- -- Substance typechecker TODO
--
-- -- ---------------------------------------
-- --
-- -- -- Style grammar (relies on the Substance grammar, specifically SubObj)
-- -- -- no styling for constraints
-- --
-- -- data SetShape = SetCircle | Box
-- --      deriving (Show, Eq)
-- --
-- -- data PtShape = SolidDot | HollowDot | Cross
-- --      deriving (Show, Eq)
-- --
-- -- -- data MapShape = LeftArr | RightArr | DoubleArr
-- -- data MapShape = SolidArrow
-- --      deriving (Show, Eq)
-- --
-- -- data Direction = Horiz | Vert | Angle Float
-- --      deriving (Show, Eq)
-- --
-- -- data SubShape = SS SetShape | SP PtShape | SM MapShape
-- --      deriving (Show, Eq)
-- --
-- -- data LineType = Solid | Dotted
-- --      deriving (Show, Eq, Read)
-- --
-- -- data Color = Red | Blue | Black | Yellow -- idk
-- --      deriving (Show, Eq, Read)
-- --
-- -- data M a = Auto | Override a -- short for Maybe (option type)
-- --      deriving (Show, Eq)
-- --
-- -- data StyLevel = SubVal String | LabelOfSubVal String | SubType SubObjType | Global
-- --      deriving (Show, Eq)
-- -- -- LabelOfSubObj is meant to allow styling of whatever label object A (originally named A) now has
-- -- -- e.g. it could be named "hello" with Label (SubValue "A") (Override "Hello"). (don't label labels)
-- -- -- then do (Position (LabelOfSubObj "A") 100 200)
-- --
-- -- type Opacity = Float -- 0 to 100%, TODO validate
-- -- type Priority' = Float -- higher = higher priority
-- --
-- -- -- There are three different layers of Style: global setting (over all types),
-- -- -- type setting (over all values of that type), and value setting.
-- -- -- The more specific ones implicitly override the more general ones.
-- -- -- If there are two conflicting ones at the same level, the more recent one will be used for "everything"
-- -- -- TODO more sophisticated system with scope
-- -- -- TODO if some aspect of style unspecified, then supplement with default
-- -- -- any setting is implicitly an override of the global default style
-- -- -- can choose to leave out an aspect (= implicitly auto), or explicitly specify auto; same thing
-- -- -- TODO need to validate that the shape specified matches that of the type
-- -- -- e.g. Shape Map Diamond is invalid
-- -- -- also, order does not matter between lines
-- -- data StyLine = Shape StyLevel (M SubShape) -- implicitly solid unless line is specified
-- --                | Line StyLevel (M LineType) (M Float) -- hollow shape; non-negative thickness
-- --                | Color StyLevel (M Color) (M Opacity)
-- --                | Priority StyLevel (M Priority') -- for line breaking
-- --                | Dir StyLevel (M Direction)
-- --                | Label StyLevel (M String) -- TODO add ability to turn off labeling
-- --                | Scale StyLevel (M Float) -- scale factor
-- --                | AbsPos StyLevel (M (Float, Float)) -- in pixels; TODO relative positions
-- --      deriving (Show, Eq)
-- --
-- -- type StySpec = [StyLine]
-- --
-- -- -- Sample Style programs and tests
-- -- -- TODO style is more complicated than substance; this doesn't test it fully
-- --
-- nl = "\n"
-- together = intercalate nl
-- -- sty0 = "Shape Global Circle"
-- -- sty1 = "Shape Set Box"
-- -- sty2 = "Shape A Circle"
-- -- sty3 = together [sty0, sty1, sty2] -- test overrides
-- -- sty4 = "Shape Set Circle\nShape Map RightArr\nLine Map Solid"
-- -- sty5 = "Line Map Dotted 5.01"
-- -- sty6 = "Color All Red 66.7"
-- -- sty7 = "Priority Label_AB 10.1"
-- -- sty8 = "Label All hithere"
-- -- sty9 = "Label Label_AB oh_no" -- TODO don't label labels. also allow spaces in labels (strings)
-- -- sty10 = "Direction Map Horizontal"
-- -- -- test all
-- -- sty_all = "Shape Set Circle\nShape Map RightArrow\nLine Map Solid Auto\nColor Global Blue 100\nPriority Map 100\nPriority Set 50\nDirection Map Horizontal\nDirection A Vertical\nLabel A NewA\nScale A 100\nPosition A -100 501\nColor Label_A Blue 100"
-- -- -- TODO deal with OpenSet, ClosedSet
-- -- -- TODO write tests of substance working *with* style
-- --
-- -- -- TODO add tests that should fail
-- -- styf1 = "Shape"
-- -- styf2 = "Shape Label_A"
-- -- styf3 = "Line Dotted 5.01"
-- --
-- -- -- TODO syntactically valid but semantically invalid programs
-- -- styfs1 = "Shape Map Circle"
-- --
-- -- -- Style parser
-- -- styParse :: String -> StySpec -- same as subParse
-- -- styParse = map (styToLine . words) . filter nonempty . lines
-- --          where nonempty x = (x /= "")
-- --
-- -- getLevel :: String -> StyLevel
-- -- getLevel s = if s == "All" then Global
-- --              -- TODO will need to update parsers whenever I add a new type...
-- --              else if s == "Set" then SubType (Set Unspecified)
-- --              else if s == "OpenSet" then SubType (Set Open)
-- --              else if s == "ClosedSet" then SubType (Set Closed)
-- --              else if s == "Point" then SubType Pt
-- --              else if s == "Map" then SubType Map
-- --              else if (take 6 s == "Label_")
-- --                   then let res = drop 6 s in
-- --                        if length res > 0 then LabelOfSubVal res
-- --                        else error "Empty object name ('Label_') in style level"
-- --              else SubVal s -- sets could be named anything; later we validate that this ref exists
-- --
-- -- getShape :: [String] -> M SubShape
-- -- getShape [] = error "No Style shape param"
-- -- getShape [x] = if x == "Auto" then Auto
-- --                else if x == "Circle" then Override (SS SetCircle)
-- --                else if x == "Box" then Override (SS Box)
-- --                else if x == "SolidDot" then Override (SP SolidDot)
-- --                else if x == "HollowDot" then Override (SP HollowDot)
-- --                else if x == "Cross" then Override (SP Cross)
-- --                else if x == "SolidArrow" then Override (SM SolidArrow)
-- --             --    else if x == "LeftArrow" then Override (SM LeftArr)
-- --             --    else if x == "RightArrow" then Override (SM RightArr)
-- --             --    else if x == "DoubleArrow" then Override (SM DoubleArr)
-- --                else error $ "Invalid shape param '" ++ show x ++ "'"
-- -- getShape s = error $ "Too many style shape params in '" ++ show s ++ "'"
-- --
-- -- handleAuto :: String -> (String -> a) -> M a
-- -- handleAuto v f = if v == "Auto" then Auto else Override (f v)
-- --
-- -- readFloat :: String -> Float
-- -- readFloat x = read x :: Float
-- --
-- -- styToLine :: [String] -> StyLine
-- -- styToLine [] = error "Style spec line is empty"
-- -- styToLine s@[x] = error $ "Style spec line '" ++ show s ++ "' is only 1 token"
-- -- styToLine s@(x : y : xs) =
-- --           let level = getLevel y in -- throws its own errors
-- --           if x == "Shape" then
-- --              let shp = getShape xs in -- TODO handle Auto
-- --              Shape level shp
-- --           else if x == "Line" then
-- --              case xs of
-- --              [a, b] -> let ltype = handleAuto a (\x -> read x :: LineType) in -- TODO read is hacky, bad errorsn
-- --                        let lthick = handleAuto b readFloat in
-- --                        Line level ltype lthick
-- --              _ -> error $ "Incorrect number of params (not 3) for Line: '" ++ show xs ++ "'"
-- --           else if x == "Color" then
-- --                case xs of
-- --                [a, b] -> let ctype = handleAuto a (\x -> read x :: Color) in
-- --                          let opacity = handleAuto b readFloat in
-- --                          Color level ctype opacity
-- --                _ -> error $ "Incorrect # of params (not 3) for Color: '" ++ show xs ++ "'"
-- --           else if x == "Priority" then
-- --                case xs of
-- --                [a] -> let priority = handleAuto a readFloat in
-- --                       Priority level priority
-- --                _  -> error $ "Incorrect number of params (not 2) for Priority: '" ++ show xs ++ "'"
-- --           else if x == "Direction" then
-- --                case xs of
-- --                [a] -> let dir = handleAuto a (\x -> if x == "Horizontal" then Horiz
-- --                                                     else if x == "Vertical" then Vert
-- --                                                     else Angle (read x :: Float)) in
-- --                       Dir level dir
-- --                _  -> error $ "Incorrect number of params (not 2) for Direction: '" ++ show xs ++ "'"
-- --           else if x == "Label" then
-- --                case xs of
-- --                [a] -> Label level (handleAuto a id) -- label name is a string
-- --                _  -> error $ "Incorrect number of params (not 2) for Label: '" ++ show xs ++ "'"
-- --           else if x == "Scale" then
-- --                case xs of
-- --                [a] -> let scale = handleAuto a readFloat in
-- --                       Scale level scale
-- --                _  -> error $ "Incorrect number of params (not 2) for Scale: '" ++ show xs ++ "'"
-- --           else if x == "Position" then
-- --                case xs of
-- --                [a] -> if a == "Auto" then AbsPos level Auto
-- --                       else error $ "Only 1 param, but it is not Auto: '" ++ show a ++ "'"
-- --                [a, b] -> let x' = readFloat a in -- no Auto allowed if two params
-- --                          let y' = readFloat b in
-- --                          AbsPos level (Override (x', y'))
-- --                _  -> error $ "Incorrect number of params (not 2) for Position: '" ++ show xs ++ "'"
-- --           else error $ "Style spec line: '" ++ show s
-- --                ++ "' does not begin with Shape/Line/Color/Priority/Direction/Label/Scale/Position"
-- --
-- -- -- Pretty-printer for Style AST
-- -- -- TODO write the full pretty-printer
-- -- styPrettyPrintLine :: StyLine -> String
-- -- styPrettyPrintLine = show
-- --
-- -- styPrettyPrint :: StySpec -> String
-- -- styPrettyPrint s = concat $ intersperse nl $ map styPrettyPrintLine s
-- --
-- -- -- Style validater
-- --
-- -- -- Style typechecker TODO
-- --
-- -- -- Style reference checker
-- --
-- -- ---------------------------------------
-- --
-- -- -- Take a Substance and Style program, and produce the abstract layout representation
-- --
-- -- -- TODO try doing this w/o Style first? everything is compiled to a default style with default labels
-- -- -- write out applying Style on top: applying global overrides, then by type, then by name
-- -- -- going to need some kind of abstract intermediate type
-- -- -- figure out the intermediate subsets of the language I can support
-- --   -- e.g. map requires me to draw arrows, don't support direction and priority for now
-- -- -- how many objects I can support, e.g. A -> B -> C -> D requires scaling the size of each obj to fit on canvas
-- -- -- how the optimization code needs to scale up to meet the needs of multiple objects (labels only?)
-- -- -- also, optimization on multiple layouts
-- -- -- how to lay things out w/ constraints only (maybe)
-- -- -- how to apply optimization to the labels & what their obj functions should be
-- --
-- -- -- TODO finish parser for both, put into Slack tonight w/ description of override, continuousmap1.sub/sty
-- --
-- -- -- Substance only, circular sets only -> world state
-- -- -- then scale up optimization code to handle any number of sets
-- -- -- then support the Subset constraint only
-- -- -- then add labels and set styles
-- -- subt1 = "Set A"
-- -- subt2 = "Set A\nSet B"
-- -- subt2a = "Set A\nSet B\nSubset A B"
-- -- subt3 = "Set A\nSet B\nSet C"
-- -- subt4 = "Set A\nSet B\nSet C"
-- -- subt4a = "Set A\nSet B\nOpenSet C"
-- -- subt5 = "Set A\nSet B\nOpenSet C\nSubset B C"
-- -- styt1 = "Color Set Blue 50"
-- -- styt2 = "Color Set Blue 50\nLine OpenSet Dotted 1"
-- --
-- -- -- New type: inner join (?) of Decl with relevant constraint lines and relevant style lines
-- -- -- (only the ones that apply; not the ones that are overridden)
-- -- -- Type: Map Var (Decl, [SubConstr], [StyLine]) <-- the Var is the object's name (string) in Substance
-- -- -- does this include labels?? it includes overridden labels in StyLine but not labels like Set A -> "A"
-- -- -- for now, assume what about labels? -- are they separate? should they be linked? they all get default style
-- --   -- make a separate Map Label ObjName ? no, assuming no renaming for now
-- -- -- then we need to write a renderer type: Decl -> (Position, Size) -> [StyLine] -> Picture)
-- --   -- also (Label -> (Position, Size) -> [StyLine] -> Picture)
-- --
-- -- -- if we do a demo entirely w/o optimization... is that easier? and how would I do it?
-- --   -- layout algo (for initial state, at least): randomly place objs (sets, points) w/ no constraints
-- --   -- or place aligned horizontally so they don't intersect, choose radius as fn of # unconstrained objs?
-- --   -- for constraints: for any set that's a subset of another, pick a smaller radius & place it inside that set.
-- --   -- constraints: same for points (in fact, easier for points)--place it (at r/2, 45 degrees) inside that set
-- --   -- there's no validation... a point/set could be in multiple sets?? assume not
-- --   -- at this point we're almost hardcoding the diagram? not necessarily
-- --   -- TODO actually hardcode the diagram in gloss; seeing the final representation will help
-- --   -- add'l constraint: all other objects should not intersect. use optimization to maintain exclusion?
-- -- -- it seems likely that i'll get rid of the opt part for diagrams--might rewrite code instead of using opt code
-- --
-- -- -- BUT can I use opt for labels, given a fixed diagram state?
-- --   -- put all labels in center. set label is attracted to center or just-outside-or-inside border of set,
-- --   -- point label is attracted to just-outside-point, map label attracted to center
-- --   -- all labels repulsed from other objects and labels.
-- --   -- would hardcoding label locations be a bad thing to do?
-- --   -- creating unconstrained objective fn: f :: DiagramInfo -> LabelInfo -> Label Positions -> Label Positions
-- --   -- where f info pos = f_attract info pos + f_repel info pos, and each includes the pairwise interactions
-- --   -- can autodiff deal with this? does this preserve the (forall a. Floating a => [a] -> a) type?
-- --   -- is the function too complicated for autodiff?
-- --
-- -- -- TODO simple optimizer type, using state (Position and Size): ??
-- --   -- optimization fn: put all sets at the center, then use centerAndRepel. how to maintain subset?
-- -- -- the things the optimizer needs to know are Name, Position, Size, SubObjType (which includes names of other objects that this one is linked to, e.g. Map)... (later: needs to know Direction Label Scale AbsPos)
-- -- -- and it updates the Position and possibly the Size
-- --
-- -- -- TODO how to synthesize the objective functions and constraint functions and implicit constraints?
-- -- -- pairwise interactions? see above
-- --
-- -- -- Since the compiler and the runtime share the layout representation,
-- -- -- I'm going to re-type it here since the rep may change.
-- -- -- Runtime imports Compiler as qualified anyway, so I can just convert the types again there.
-- -- -- Here: removing selc / sell (selected). Don't forget they should satisfy Located typeclass
-- -- data Circ = Circ { namec :: String
-- --                  , xc :: Float
-- --                  , yc :: Float
-- --                  , r :: Float }
-- --      deriving (Eq, Show)
-- --
-- -- data Label' = Label' { xl :: Float
-- --                    , yl :: Float
-- --                    , textl :: String
-- --                    , scalel :: Float }  -- calculate h,w from it
-- --      deriving (Eq, Show)
-- --
-- -- data Obj = C Circ | L Label' deriving (Eq, Show)
-- --
-- -- defaultRad = 100
-- --
-- -- -- TODO these functions are now unused
-- -- -- declToShape :: SubDecl -> [Obj]
-- -- -- declToShape (Decl (OS (Set' name setType))) =
-- -- --             case setType of
-- -- --             Open -> [C $ Circ { namec = name, xc = 0, yc = 0, r = defaultRad }, L $ Label' { xl = 0, yl = 0, textl = name, scalel = 1 }]
-- -- --             Closed -> [C $ Circ { namec = name, xc = 0, yc = 0, r = defaultRad }, L $ Label' { xl = 0, yl = 0, textl = name, scalel = 1 }]
-- -- --             Unspecified -> [C $ Circ { namec = name, xc = 0, yc = 0, r = defaultRad }, L $ Label' { xl = 0, yl = 0, textl = name, scalel = 1 }]
-- -- -- declToShape (Decl (OP (Pt' name))) = error "Substance -> Layout doesn't support points yet"
-- -- -- declToShape (Decl (OM (Map' mapName fromSet toSet))) = error "Substance -> Layout doesn't support maps yet"
-- --
-- -- -- toStateWithDefaultStyle :: [SubDecl] -> [Obj]
-- -- -- toStateWithDefaultStyle decls = concatMap declToShape decls -- should use style
-- --
-- -- -- subToLayoutRep :: SubSpec -> [Obj] -- this needs to know about the Obj type??
-- -- -- subToLayoutRep spec = let (decls, constrs) = subSeparate spec in
-- -- --                    toStateWithDefaultStyle decls
-- --
-- -- -- Substance + Style typechecker
-- --
-- -- -- Substance + Style reference checker
-- --
-- -- -- Produce the constraints and objective function
-- --
-- -- -- Add rendering and interaction info to produce a world state for gloss
-- --
-- -- ---------------------------------------
-- --
-- -- -- Runtime: layout algorithm picks a smart initial state
-- -- -- then tries to satisfy constraints and minimize objective function, live and interactively
-- -- -- TODO make module for this and optimization code
-- --
-- -- ---------------------------------------
-- --
-- -- -- ghc compiler.hs; ./compiler <filename>.sub
-- -- parseSub = do
-- --        args <- getArgs
-- --        let fileIn = head args
-- --        program <- readFile fileIn
-- --        putStrLn $ show $ subParse program
-- --        putStrLn $ show $ subValidate program
-- --
-- -- -- ghc compiler.hs; ./compiler <filename>.sty
-- -- parseSty = do
-- --        args <- getArgs
-- --        let fileIn = head args
-- --        program <- readFile fileIn
-- --        putStrLn $ styPrettyPrint $ styParse program
-- --
-- -- -- ghc compiler.hs; ./compiler <filename>.sub <filename>.sty
-- -- subAndSty = do
-- --        args <- getArgs
-- --        let (subFile, styFile) = (head args, args !! 1) -- TODO usage
-- --        subIn <- readFile subFile
-- --        styIn <- readFile styFile
-- --        putStrLn $ subPrettyPrint $ subParse subIn
-- --        putStrLn "--------"
-- --        putStrLn $ styPrettyPrint $ styParse styIn
-- --
-- -- main = subAndSty

--------------------------------------------------------------------------------
-- Test driver: First uncomment the module definition to make this module the -- Main module. Usage: ghc Substance; ./Substance <substance-file>

parseFromFile p file = runParser p file <$> readFile file

main :: IO ()
main = do
    args <- getArgs
    let subFile = head args
    subIn <- readFile subFile
    -- putStrLn styIn
    -- parseTest styleParser styIn
    case runParser substanceParser subFile subIn of
         Left err -> putStr (parseErrorPretty err)
         Right xs -> do
             mapM_ print xs
             divLine
             let c = check xs
             let al = toAlloy c
             mapM_ print al
             divLine
             mapM_ (putStrLn . prettyShow) al
             let pretty_al = concatMap ((++ "\n") . prettyShow)  al
             writeFile "./alloy/pretty.als" pretty_al
            --  mapM_ print os
            --  print m
            --  divLine
            --  let (decls, constrs) = subSeparate os
            --  mapM_ print decls
            --  divLine
            --  mapM_ print constrs
    return ()
