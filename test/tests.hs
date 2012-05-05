{-# LANGUAGE GADTs, TypeFamilies, TemplateHaskell, QuasiQuotes, RankNTypes, ScopedTypeVariables, FlexibleContexts, StandaloneDeriving #-}
module Main where
import qualified Data.Map as M
import qualified Control.Exception as E
import Control.Exception.Base (SomeException)
import Control.Monad (replicateM_, liftM, forM_, (>=>), unless)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Control (MonadBaseControl, control)
import Database.Groundhog.Core
import Database.Groundhog.Generic.Sql
import Database.Groundhog.TH
import Database.Groundhog.Sqlite
import Database.Groundhog.Postgresql
import Data.Int
import qualified Data.Map as Map
import Data.Word
import Test.Framework (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
import qualified Migration.Old as Old
import qualified Migration.New as New
import qualified Test.HUnit as H
import Prelude hiding (catch)

data Number = Number {int :: Int, int8 :: Int8, word8 :: Word8, int16 :: Int16, word16 :: Word16, int32 :: Int32, word32 :: Word32, int64 :: Int64, word64 :: Word64} deriving (Eq, Show)
data MaybeContext a = MaybeContext (Maybe a) deriving (Eq, Show)
data Single a = Single {single :: a} deriving (Eq, Show)
data Multi a = First {first :: Int} | Second {second :: a} deriving (Eq, Show)
data Settable = Settable {settable1 :: String, settable2 :: String, settableTuple :: (Int, (String, Int))} deriving (Eq, Show)
data Keys = Keys {refDirect :: Single String, refKey :: Key (Single String), refDirectMaybe :: Maybe (Single String), refKeyMaybe :: Maybe (Key (Single String))}
data EmbeddedSample = EmbeddedSample {embedded1 :: String, embedded2 :: (Int, Int)} deriving (Eq, Show)
-- cannot use ordinary deriving because it runs before mkPersist and requires (Single String) to be an instance of PersistEntity
deriving instance Eq Keys
deriving instance Show Keys

mkPersist suffixNamingStyle [groundhog|
- entity: Number
- entity: MaybeContext
- entity: Single
- entity: Multi
- entity: Keys
- entity: Settable
  dbName: sqlsettable
  constructors:
    - name: Settable
      phantomName: SettableFooBarConstructor
      dbName: entity_db_name_is_used_instead
      fields:
        - name: settable1
          dbName: sqlsettable1
          exprName: Settable1Fld
        - name: settableTuple
          embeddedType:
            - name: val0
              dbName: firstTupleElement
            - name: val1
              embeddedType:
                - name: val0
                  dbName: secondTupleElement
                - name: val1
                  dbName: thirdTupleElement
              dbName: name
      constraints:
        - name: someconstraint
          fields: [settable1, settable2]
- embedded: EmbeddedSample
  fields:
    - name: embedded2
      embeddedType:
        - name: val0
          dbName: embeddedTuple0
        - name: val1
          dbName: embeddedTuple1
|]

main :: IO ()
main = do
  let runSqlite m = withSqliteConn ":memory:" . runSqliteConn $ m
  let runPSQL m = withPostgresqlConn "dbname=test user=test password=test host=localhost" . runPostgresqlConn $ clean >> m
  -- we need clean db before each migration test
  defaultMain [ sqliteMigrationTestSuite $ withSqliteConn ":memory:" . runSqliteConn
              , mkTestSuite "Database.Groundhog.Sqlite" runSqlite
              , mkTestSuite "Database.Groundhog.Postgresql" runPSQL
              ]

migr :: (PersistEntity v, PersistBackend m, MonadBaseControl IO m, MonadIO m) => v -> m ()
migr v = runMigration silentMigrationLogger (migrate v)

mkTestSuite :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => String -> (m () -> IO ()) -> Test
mkTestSuite label run = testGroup label
  [ testCase "testNumber" $ run testNumber
  , testCase "testPersistSettings" $ run testPersistSettings
  , testCase "testEmbedded" $ run testEmbedded
  , testCase "testInsert" $ run testInsert
  , testCase "testSelect" $ run testSelect
  , testCase "testCond" $ run testCond
  , testCase "testCount" $ run testCount
  , testCase "testUpdate" $ run testUpdate
  , testCase "testComparison" $ run testComparison
  , testCase "testEncoding" $ run testEncoding
  , testCase "testDelete" $ run testDelete
  , testCase "testDeleteByKey" $ run testDeleteByKey
  , testCase "testReplaceSingle" $ run testReplaceSingle
  , testCase "testReplaceMulti" $ run testReplaceMulti
  , testCase "testTuple" $ run testTuple
  , testCase "testTupleList" $ run testTupleList
  , testCase "testListTriggersOnDelete" $ run testListTriggersOnDelete
  , testCase "testListTriggersOnUpdate" $ run testListTriggersOnUpdate
  , testCase "testMigrateAddColumnSingle" $ run testMigrateAddColumnSingle
  , testCase "testMigrateAddConstructorToMany" $ run testMigrateAddConstructorToMany
  , testCase "testLongNames" $ run testLongNames
  , testCase "testReference" $ run testReference
  , testCase "testMaybeReference" $ run testMaybeReference
  , testCase "testDoubleMigration" $ run testDoubleMigration
  ]
  
sqliteMigrationTestSuite :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => (m () -> IO ()) -> Test
sqliteMigrationTestSuite run = testGroup "Database.Groundhog.Sqlite.Migration"
  [ testCase "testOrphanConstructors" $ run testOrphanConstructors
  ]

(@=?) :: (Eq a, Show a, MonadBaseControl IO m, MonadIO m) => a -> a -> m ()
expected @=? actual = liftIO $ expected H.@=? actual

testOrphanConstructors :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testOrphanConstructors = do
  migr (undefined :: Multi String)
  executeRaw False "drop table Multi$String" []
  mig <- createMigration (migrate (undefined :: Multi String))
  [("Multi$String", Left ["Orphan constructor table found: Multi$String$First","Orphan constructor table found: Multi$String$Second"])] @=? M.toList mig

testNumber :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testNumber = do
  migr (undefined :: Number)
  let minNumber = Number minBound minBound minBound minBound minBound minBound minBound minBound minBound
  let maxNumber = Number maxBound maxBound maxBound maxBound maxBound maxBound maxBound maxBound maxBound
  minNumber' <- insert minNumber >>= get
  maxNumber' <- insert maxNumber >>= get
  Just minNumber @=? minNumber'
  Just maxNumber @=? maxNumber'

testPersistSettings :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testPersistSettings = do
  let settable = Settable "abc" "def" (1, ("qqq", 2))
  migr settable
  k <- insert settable
  (settable' :: Maybe Settable) <- queryRaw False "select 0, \"sqlsettable1\", \"settable2\", \"firstTupleElement\", \"secondTupleElement\", \"thirdTupleElement\" from \"sqlsettable\" where id$=?" [toPrim k] (firstRow >=> maybe (return Nothing) (fmap Just . fromEntityPersistValues))
  Just settable @=? settable'
  vals <- select (Settable1Fld ==. "abc" &&. SettableTupleField ~> Tuple2_0Selector ==. (1 :: Int) &&. SettableTupleField ~> Tuple2_1Selector ~> Tuple2_0Selector ==. "qqq") [] 0 0
  [(k, settable)] @=? vals
  assertExc "Uniqueness constraint not enforced" $ insert settable

testEmbedded :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testEmbedded = do
  let val1 = Single (EmbeddedSample "abc" (5, 6))
  migr val1
  k1 <- insert val1
  val1' <- get k1
  Just val1 @=? val1'
  vals <- select (SingleField ~> Embedded1Selector ==. "abc" &&. SingleField ~> Embedded2Selector ==. (5, 6) &&. SingleField ~> Embedded2Selector ~> Tuple2_0Selector ==. (5 :: Int)) [] 0 0
  [(k1, val1)] @=? vals
  let val2 = Single ((EmbeddedSample "abc" (5, 6), "def"))
  migr val2
  k2 <- insert val2
  val2' <- get k2
  Just val2 @=? val2'

testInsert :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testInsert = do
  migr (undefined :: Single String)
  let val = Single "abc"
  k <- insert val
  val' <- get k
  Just val @=? val'

testSelect :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testSelect = do
  migr (undefined :: Single (Int, String))
  let val1 = Single (5 :: Int, "abc")
  let val2 = Single (7 :: Int, "def")
  let val3 = Single (11 :: Int, "ghc")
  k1 <- insert val1
  k2 <- insert val2
  k3 <- insert val3
  vals1 <- select (SingleField ~> Tuple2_0Selector >. (5 :: Int)) [Asc (SingleField ~> Tuple2_1Selector)] 0 1
  [(k3, val3)] @=? vals1
  vals2 <- select (SingleField ~> Tuple2_0Selector >. (5 :: Int)) [Asc (SingleField ~> Tuple2_1Selector)] 1 0
  [(k2, val2)] @=? vals2
  vals3 <- select (SingleField >=. (6 :: Int, "something") &&. SingleField ~> Tuple2_1Selector <. "ghc") [] 1 0
  [(k2, val2)] @=? vals3
  vals4 <- select (toArith (SingleField ~> Tuple2_0Selector) + 1 >. (10 :: Int)) [] 0 0
  [(k3, val3)] @=? vals4

testCond :: forall m . (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testCond = do
  let rend :: forall v c s . (StringLike s, PersistEntity v) => Cond v c -> Maybe (RenderS s)
      rend = renderCond id (fromString "id") (\a b -> a <> fromString "=" <> b) (\a b -> a <> fromString "<>" <> b)
  let (===) :: forall v c . PersistEntity v => (String, [PersistValue]) -> Cond v c -> m ()
      (query, vals) === cond = let Just (RenderS q v) = rend cond in (query, vals) @=? (q, v [])
      
  -- should cover all cases of renderCond comparison rendering
  ("int=?", [toPrim (4 :: Int)]) === (IntField ==. (4 :: Int))
  ("int=int", []) === (IntField ==. IntField)
  ("int=(int+?)*?", [toPrim (1 :: Int), toPrim (2 :: Int)]) === (IntField ==. (toArith IntField + 1) * 2)

  ("single$val0=? AND single$val1=?", [toPrim "abc", toPrim "def"]) === (SingleField ==. ("abc", "def"))
  ("single$val0=single$val1", []) === (SingleField ~> Tuple2_0Selector ==. SingleField ~> Tuple2_1Selector :: Cond (Single (Int, Int)) SingleConstructor)
  ("single$val1=single$val0*(?+single$val0)", [toPrim (5 :: Int)]) === (SingleField ~> Tuple2_1Selector ==. toArith (SingleField ~> Tuple2_0Selector) * (5 + toArith (SingleField ~> Tuple2_0Selector)) :: Cond (Single (Int, Int)) SingleConstructor)

  ("?=? AND ?=?", map toPrim [1, 2, 3, 4 :: Int]) === ((1 :: Int, 3 :: Int) ==. (2 :: Int, 4 :: Int) &&. SingleField ==. ()) -- SingleField ==. () is required to replace Any with a PersistEntity instance
  ("?<? OR ?<?", map toPrim [1, 2, 3, 4 :: Int]) === ((1 :: Int, 3 :: Int) <. (2 :: Int, 4 :: Int) &&. SingleField ==. ())
  ("?=single$val0 AND ?=single$val1", map toPrim [1, 2 :: Int]) === ((1 :: Int, 2 :: Int) ==. SingleField)
  ("?=single+?*?", map toPrim [1, 2, 3 :: Int]) === ((1 :: Int) ==. toArith SingleField + 2 * 3)

  ("?-single=?", map toPrim [1, 2 :: Int]) === (1 - toArith SingleField ==. (2 :: Int))
  ("?*single>=single", map toPrim [1 :: Int]) === (1 * toArith SingleField >=. SingleField :: Cond (Single Int) SingleConstructor)
  ("?+single>=single-?", map toPrim [1, 2 :: Int]) === (1 + toArith SingleField >=. toArith SingleField - 2 :: Cond (Single Int) SingleConstructor)
  
  -- test parentheses
  ("single=? OR ?=? AND ?=?", map toPrim [0, 1, 2, 3, 4 :: Int]) === (SingleField ==. (0 :: Int) ||. (1 :: Int, 3 :: Int) ==. (2 :: Int, 4 :: Int))
  ("single=? AND (?<? OR ?<?)", map toPrim [0, 1, 2, 3, 4 :: Int]) === (SingleField ==. (0 :: Int) &&. (1 :: Int, 3 :: Int) <. (2 :: Int, 4 :: Int))
  ("single=? AND (single=single OR single<>single)", map toPrim [0 :: Int]) === (SingleField ==. (0 :: Int) &&. (SingleField ==. SingleField ||. SingleField /=. SingleField))
  
  -- test empty conditions
  ("single$val0=? AND single$val1=?", [toPrim "abc", toPrim "def"]) === (SingleField ==. ("abc", "def") &&. (() ==. () ||. ((), ()) <. ((), ())))
  ("single$val0=? AND single$val1=?", [toPrim "abc", toPrim "def"]) === ((() ==. () ||. ((), ()) <. ((), ())) &&. SingleField ==. ("abc", "def"))
  

testCount :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testCount = do
  migr (undefined :: Multi String)
  insert (First 0 :: Multi String)
  insert (Second "abc")
  num <- countAll (undefined :: Multi String)
  2 @=? num
  num2 <- count $ SecondField ==. "abc"
  1 @=? num2
  migr (undefined :: Single String)
  insert $ Single "abc"
  num3 <- count (SingleField ==. "abc")
  1 @=? num3

testUpdate :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testUpdate = do
  let val = Single ("abc", "def")
  migr val
  k <- insert val
  -- update columns using embedded data structure
  update [SingleField =. ("ghc", "qqq")] (SingleField ~> Tuple2_0Selector ==. "abc")
  val1 <- get k
  Just (Single ("ghc", "qqq")) @=? val1
  -- update columns to the initial values using embedded data structure subfields
  update [SingleField ~> Tuple2_0Selector =. "abc", SingleField ~> Tuple2_1Selector =. "def"] (KeyIs k)
  val2 <- get k
  Just val @=? val2

testComparison :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testComparison = do
  let val1 = Single (1 :: Int)
  let val2 = Single (2 :: Int)
  migr val1
  k1 <- insert val1
  k2 <- insert val2
  result1 <- select (SingleField ==. (1 :: Int)) [] 0 0
  [(k1, val1)] @=? result1
  result2 <- select (SingleField /=. (1 :: Int)) [] 0 0
  [(k2, val2)] @=? result2
  result3 <- select (SingleField <.  (2 :: Int)) [] 0 0
  [(k1, val1)] @=? result3
  result4 <- select (SingleField >. (1 :: Int)) [] 0 0
  [(k2, val2)] @=? result4
  result5 <- select (SingleField >=. (2 :: Int)) [] 0 0
  [(k2, val2)] @=? result5
  result6 <- select (SingleField <=. (1 :: Int)) [] 0 0
  [(k1, val1)] @=? result6

testEncoding :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testEncoding = do
  let val = Single "\x0001\x0081\x0801\x10001"
  migr val
  k <- insert val
  val' <- get k
  Just val @=? val'

testTuple :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testTuple = do
  let val = Single ("abc", ("def", 5 :: Int))
  migr val
  k <- insert val
  val' <- get k
  Just val @=? val'

testTupleList :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testTupleList = do
  let val = Single [("abc", 4 :: Int), ("def", 5)]
  migr val
  k <- insert val
  val' <- get k
  Just val @=? val'
  
testListTriggersOnDelete :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testListTriggersOnDelete = do
  migr (undefined :: Single (String, [[String]]))
  k <- insert (Single ("", [["abc", "def"]]) :: Single (String, [[String]]))
  Just [listKey] <- queryRaw False "select \"single$val1\" from \"Single$Tuple2$$String$List$$List$$String\" where id$=?" [toPrim k] firstRow
  listsInsideListKeys <- queryRaw False "select value from \"List$$List$$String$values\" where id$=?" [listKey] $ mapAllRows return
  deleteByKey k
  -- test if the main list table and the associated values were deleted
  listMain <- queryRaw False "select * from \"List$$List$$String\" where id$=?" [listKey] firstRow
  Nothing @=? listMain
  listValues <- queryRaw False "select * from \"List$$List$$String$values\" where id$=?" [listKey] firstRow
  Nothing @=? listValues
  -- test if the ephemeral values associated with the list were deleted
  forM_ listsInsideListKeys $ \listsInsideListKey -> do
    sublist <- queryRaw False "select * from \"List$$String\" where id$=?" listsInsideListKey firstRow
    Nothing @=? sublist

testListTriggersOnUpdate :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testListTriggersOnUpdate = do
  migr (undefined :: Single (String, [[String]]))
  k <- insert (Single ("", [["abc", "def"]]) :: Single (String, [[String]]))
  Just [listKey] <- queryRaw False "select \"single$val1\" from \"Single$Tuple2$$String$List$$List$$String\" where id$=?" [toPrim k] firstRow
  listsInsideListKeys <- queryRaw False "select value from \"List$$List$$String$values\" where id$=?" [listKey] $ mapAllRows return
  replace k (Single ("", []) :: Single (String, [[String]]))
  -- test if the main list table and the associated values were deleted
  listMain <- queryRaw False "select * from \"List$$List$$String\" where id$=?" [listKey] firstRow
  Nothing @=? listMain
  listValues <- queryRaw False "select * from \"List$$List$$String$values\" where id$=?" [listKey] firstRow
  Nothing @=? listValues
  -- test if the ephemeral values associated with the list were deleted
  forM_ listsInsideListKeys $ \listsInsideListKey -> do
    sublist <- queryRaw False "select * from \"List$$String\" where id$=?" listsInsideListKey firstRow
    Nothing @=? sublist

testDelete :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testDelete = do
  migr (undefined :: Multi String)
  k <- insert $ Second "abc"
  delete $ SecondField ==. "abc"
  main <- queryRaw True "SELECT * FROM \"Multi$String\" WHERE id$=?" [toPrim k] firstRow
  Nothing @=? main
  constr <- queryRaw True "SELECT * FROM \"Multi$String$Second\" WHERE id$=?" [toPrim k] firstRow
  Nothing @=? constr

testDeleteByKey :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testDeleteByKey = do
  migr (undefined :: Multi String)
  k <- insert $ Second "abc"
  deleteByKey k
  main <- queryRaw True "SELECT * FROM \"Multi$String\" WHERE id$=?" [toPrim k] firstRow
  Nothing @=? main
  constr <- queryRaw True "SELECT * FROM \"Multi$String$Second\" WHERE id$=?" [toPrim k] firstRow
  Nothing @=? constr

testReplaceMulti :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testReplaceMulti = do
  migr (undefined :: Single (Multi String))
  -- we need Single to test that referenced value cam be replaced
  k <- insert $ Single (Second "abc")
  Just [valueKey'] <- queryRaw True "SELECT \"single\" FROM \"Single$Multi$String\" WHERE id$=?" [toPrim k] firstRow
  let valueKey = fromPrim valueKey'

  replace valueKey (Second "def")
  replaced <- get valueKey
  Just (Second "def") @=? replaced

  replace valueKey (First 5)
  replaced <- get valueKey
  Just (First 5) @=? replaced
  oldConstructor <- queryRaw True "SELECT * FROM \"Multi$String$Second\" WHERE id$=?" [toPrim valueKey] firstRow
  Nothing @=? oldConstructor

testReplaceSingle :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testReplaceSingle = do
  -- we need Single to test that referenced value cam be replaced
  let val = Single (Single "abc")
  migr val
  k <- insert val
  Just [valueKey'] <- queryRaw True "SELECT \"single\" FROM \"Single$Single$String\" WHERE id$=?" [toPrim k] firstRow
  let valueKey = fromPrim valueKey'
  
  replace valueKey (Single "def")
  replaced <- get valueKey
  Just (Single "def") @=? replaced

testMigrateAddColumnSingle :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testMigrateAddColumnSingle = do
  migr (undefined :: Old.AddColumn)
  migr (undefined :: New.AddColumn)
  m <- createMigration $ migrate (undefined :: New.AddColumn)
  Map.singleton "AddColumn" (Right []) @=? m
  let val = New.AddColumn "abc" 5
  k <- insert val
  val' <- get k
  Just val @=? val'

testMigrateAddConstructorToMany :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testMigrateAddConstructorToMany = do
  migr (undefined :: Old.AddConstructorToMany)
  Key k1 <- insert $ Old.AddConstructorToMany1 1
  Key k2 <- insert $ Old.AddConstructorToMany2 "abc"
  migr (undefined :: New.AddConstructorToMany)
  k0 <- insert $ New.AddConstructorToMany0 5
  val1 <- get (Key k1 :: Key New.AddConstructorToMany)
  Just (New.AddConstructorToMany1 1) @=? val1
  val2 <- get (Key k2 :: Key New.AddConstructorToMany)
  Just (New.AddConstructorToMany2 "abc") @=? val2
  val0 <- get k0
  Just (New.AddConstructorToMany0 5) @=? val0

testDoubleMigration :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testDoubleMigration = do
  let val1 = Single ([""], 0 :: Int)
  migr val1
  m1 <- createMigration (migrate val1)
  [] @=? filter (/= Right []) (Map.elems m1)

  let val2 = Single [("", Single "")]
  migr val2
  m2 <- createMigration (migrate val2)
  executeMigration silentMigrationLogger m2
  [] @=? filter (/= Right []) (Map.elems m2)

  let val3 = Second ("", [""])
  migr val3
  m3 <- createMigration (migrate val3)
  [] @=? filter (/= Right []) (Map.elems m3)
  return ()

testLongNames :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testLongNames = do
  let val = Single [(Single [Single ""], 0 :: Int, [""], (), [""])]
  migr val
  k <- insert val
  val' <- get k
  Just val @=? val'

  let val2 = Single [([""], Single "", 0 :: Int)]
  migr val2
  m2 <- createMigration (migrate val2)
  executeMigration silentMigrationLogger m2
  -- this might fail because the constraint names are too long. They constraints are created successfully, but with stripped names. Then during the second migration the stripped names differ from expected and this leads to migration errors.
  [] @=? filter (/= Right []) (Map.elems m2)


testReference :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testReference = do
  migr (undefined :: Single (Single String))
  k <- insert $ Single (Single "abc")
  Just [valueKey'] <- queryRaw True "SELECT \"single\" FROM \"Single$Single$String\" WHERE id$=?" [toPrim k] firstRow
  assertExc "Foreign key must prevent deletion" $ deleteByKey (fromPrim valueKey' :: Key (Single String))

testMaybeReference :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testMaybeReference = do
  migr (undefined :: Single (Maybe (Single String)))
  k <- insert $ Single (Just (Single "abc"))
  Just [valueKey'] <- queryRaw True "SELECT \"single\" FROM \"Single$Maybe$Single$String\" WHERE id$=?" [toPrim k] firstRow
  deleteByKey (fromPrim valueKey' :: Key (Single String))
  val' <- get k
  Just (Single Nothing) @=? val'

-- This test must just compile
testKeys :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
testKeys = do
  migr (undefined :: Keys)
  k <- insert $ Single ""
  let cond = RefDirectField ==. k ||. RefKeyField ==. k ||. RefDirectMaybeField ==. Just k ||. RefKeyMaybeField ==. Just k
  select cond [] 0 0
  return ()
  
-- TODO: write test which inserts data before adding new columns

firstRow :: Monad m => RowPopper m -> m (Maybe [PersistValue])
firstRow = id

mapAllRows :: Monad m => ([PersistValue] -> m a) -> RowPopper m -> m [a]
mapAllRows f pop = go where
  go = pop >>= maybe (return []) (f >=> \a -> liftM (a:) go)
  
createTruncateTables :: String
createTruncateTables = "CREATE OR REPLACE FUNCTION truncate_tables(username IN VARCHAR) RETURNS void AS $$\
\DECLARE\
\    statements CURSOR FOR SELECT tablename FROM pg_tables WHERE tableowner = username AND schemaname = 'public';\
\BEGIN\
\    FOR stmt IN statements LOOP\
\        EXECUTE 'TRUNCATE TABLE ' || quote_ident(stmt.tablename) || ' CASCADE;';\
\    END LOOP;\
\END;\
\$$ LANGUAGE plpgsql"

clean :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => m ()
clean = do
  executeRaw True "drop schema public cascade" []
  executeRaw True "create schema public" []

assertExc :: (PersistBackend m, MonadBaseControl IO m, MonadIO m) => String -> m a -> m ()
assertExc err m = do
  happened <- control $ \runInIO -> E.catch (runInIO $ m >> return False) (\(e :: SomeException) -> runInIO $ return True)
  unless happened $ liftIO (H.assertFailure err)
