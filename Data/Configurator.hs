{-# LANGUAGE BangPatterns, OverloadedStrings, RecordWildCards,
    ScopedTypeVariables #-}

-- |
-- Module:      Data.Configurator
-- Copyright:   (c) 2011 MailRank, Inc.
-- License:     BSD3
-- Maintainer:  Bryan O'Sullivan <bos@mailrank.com>
-- Stability:   experimental
-- Portability: portable
--
-- A simple (yet powerful) library for working with configuration
-- files.

module Data.Configurator
    (
    -- * Configuration file format
    -- $format

    -- ** Binding a name to a value
    -- $binding

    -- *** Value types
    -- $types

    -- *** String interpolation
    -- $interp

    -- ** Grouping directives
    -- $group

    -- ** Importing files
    -- $import

    -- * Loading configuration data
      autoReload
    , autoConfig
    -- * Lookup functions
    , lookup
    , lookupDefault
    -- * Low-level loading functions
    , load
    , reload
    -- * Helper functions
    , display
    , getMap
    ) where

import Control.Applicative ((<$>))
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Exception (SomeException, catch, evaluate, throwIO, try)
import Control.Monad (foldM, join)
import Data.Configurator.Instances ()
import Data.Configurator.Parser (interp, topLevel)
import Data.Configurator.Types.Internal
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Monoid (mconcat)
import Data.Text.Lazy.Builder (fromString, fromText, toLazyText)
import Data.Text.Lazy.Builder.Int (decimal)
import Prelude hiding (catch, lookup)
import System.Directory (getModificationTime)
import System.Environment (getEnv)
import System.Time (ClockTime(..))
import qualified Data.Attoparsec.Text as T
import qualified Data.Attoparsec.Text.Lazy as L
import qualified Data.HashMap.Lazy as H
import qualified Data.Text as T
import qualified Data.Text.Lazy as L
import qualified Data.Text.Lazy.IO as L

loadFiles :: [Path] -> IO (H.HashMap Path [Directive])
loadFiles = foldM go H.empty
 where
   go seen path = do
     ds <- loadOne . T.unpack =<< interpolate path H.empty
     let !seen'    = H.insert path ds seen
         notSeen n = not . isJust . H.lookup n $ seen
     foldM go seen' . filter notSeen . importsOf $ ds
  
-- | Create a 'Config' from the contents of the named files. Throws an
-- exception on error, such as if files do not exist or contain errors.
load :: [FilePath] -> IO Config
load paths0 = do
  let paths = map T.pack paths0
  ds <- loadFiles paths
  m <- newIORef =<< flatten paths ds
  return Config {
               cfgPaths = paths
             , cfgMap = m
             }

-- | Forcibly reload a 'Config'. Throws an exception on error, such as
-- if files no longer exist or contain errors.
reload :: Config -> IO ()
reload Config{..} =
    writeIORef cfgMap =<< flatten cfgPaths =<< loadFiles cfgPaths

-- | Defaults for automatic 'Config' reloading when using
-- 'autoReload'.  The 'interval' is one second, while the 'onError'
-- action ignores its argument and does nothing.
autoConfig :: AutoConfig
autoConfig = AutoConfig {
               interval = 1
             , onError = const $ return ()
             }

-- | Load a 'Config' from the given 'FilePath's.
--
-- At intervals, a thread checks for modifications to both the
-- original files and any files they refer to in @import@ directives,
-- and reloads the 'Config' if any files have been modified.
--
-- If the initial attempt to load the configuration files fails, an
-- exception is thrown.  If the initial load succeeds, but a
-- subsequent attempt fails, the 'onError' handler is invoked.
autoReload :: AutoConfig
           -- ^ Directions for when to reload and how to handle
           -- errors.
           -> [FilePath]
           -- ^ Configuration files to load.
           -> IO (Config, ThreadId)
autoReload AutoConfig{..} _
    | interval < 1 = error "autoReload: negative interval"
autoReload _ []    = error "autoReload: no paths to load"
autoReload AutoConfig{..} paths = do
  cfg <- load paths
  let loop newest = do
        threadDelay (max interval 1 * 1000000)
        newest' <- getNewest paths
        if newest' == newest
          then loop newest
          else (reload cfg `catch` onError) >> loop newest'
  tid <- forkIO $ loop =<< getNewest paths
  return (cfg, tid)
  
getNewest :: [FilePath] -> IO ClockTime
getNewest = flip foldM (TOD 0 0) $ \t -> fmap (max t) . getModificationTime

-- | Look up a name in the given 'Config'.  If a binding exists, and
-- the value can be 'convert'ed to the desired type, return the
-- converted value, otherwise 'Nothing'.
lookup :: Configured a => Config -> Name -> IO (Maybe a)
lookup Config{..} name =
    (join . fmap convert . H.lookup name) <$> readIORef cfgMap

-- | Look up a name in the given 'Config'.  If a binding exists, and
-- the value can be converted to the desired type, return it,
-- otherwise return the default value.
lookupDefault :: Configured a =>
                 a
              -- ^ Default value to return if 'lookup' or 'convert'
              -- fails.
              -> Config -> Name -> IO a
lookupDefault def cfg name = fromMaybe def <$> lookup cfg name

-- | Perform a simple dump of a 'Config' to @stdout@.
display :: Config -> IO ()
display Config{..} = print =<< readIORef cfgMap

-- | Fetch the 'H.HashMap' that maps names to values.
getMap :: Config -> IO (H.HashMap Name Value)
getMap = readIORef . cfgMap

flatten :: [Path] -> H.HashMap Path [Directive] -> IO (H.HashMap Name Value)
flatten roots files = foldM (directive "") H.empty .
                      concat . catMaybes . map (`H.lookup` files) $ roots
 where
  directive prefix m (Bind name (String value)) = do
      v <- interpolate value m
      return $! H.insert (T.append prefix name) (String v) m
  directive prefix m (Bind name value) =
      return $! H.insert (T.append prefix name) value m
  directive prefix m (Group name xs) = foldM (directive prefix') m xs
      where prefix' = T.concat [prefix, name, "."]
  directive prefix m (Import path) =
      case H.lookup path files of
        Just ds -> foldM (directive prefix) m ds
        _       -> return m

interpolate :: T.Text -> H.HashMap Name Value -> IO T.Text
interpolate s env
    | "$" `T.isInfixOf` s =
      case T.parseOnly interp s of
        Left err   -> throwIO $ ParseError "" err
        Right xs -> (L.toStrict . toLazyText . mconcat) <$> mapM interpret xs
    | otherwise = return s
 where
  interpret (Literal x)   = return (fromText x)
  interpret (Interpolate name) =
      case H.lookup name env of
        Just (String x) -> return (fromText x)
        Just (Number n) -> return (decimal n)
        Just _          -> error "type error"
        _ -> do
          e <- try . getEnv . T.unpack $ name
          case e of
            Left (_::SomeException) ->
                throwIO . ParseError "" $ "no such variable " ++ show name
            Right x -> return (fromString x)

importsOf :: [Directive] -> [Path]
importsOf (Import path : xs) = path : importsOf xs
importsOf (Group _ ys : xs)  = importsOf ys ++ importsOf xs
importsOf (_ : xs)           = importsOf xs
importsOf _                  = []

loadOne :: FilePath -> IO [Directive]
loadOne path = do
  s <- L.readFile path
  p <- evaluate (L.eitherResult $ L.parse topLevel s)
       `catch` \(e::ConfigError) ->
       throwIO $ case e of
                   ParseError _ err -> ParseError path err
  case p of
    Left err -> throwIO (ParseError path err)
    Right ds -> return ds

-- $format
--
-- A configuration file consists of a series of directives and
-- comments.  Configuration files must be encoded in UTF-8.  A comment
-- begins with a \"@#@\" character, and continues to the end of a
-- line.

-- $binding
--
-- A binding associates a name with a value.
--
-- > my_string = "hi mom! \u2603"
-- > your-int-33 = 33
-- > his_bool = on
-- > HerList = [1, "foo", off]
--
-- A name must begin with a Unicode letter, which is followed by zero
-- or more of a Unicode alphanumeric code point, hyphen \"@-@\", or
-- underscore \"@_@\".

-- $types
--
-- The configuration file format supports the following data types:
--
-- * Booleans, represented as @on@ or @off@, @true@ or @false@.  These
--   are case sensitive, so do not try to use @True@ instead of
--   @true@!
--
-- * Integers, represented in base 10.
--
-- * Unicode strings, represented as text (possibly containing escape
--   sequences) surrounded by double quotes.
--
-- * Heterogeneous lists of values, represented as an opening square
--   bracket \"@[@\", followed by a series of comma-separated values,
--   ending with a closing square bracket \"@]@\".
--
-- The following escape sequences are recognised in a text string:
--
-- * @\\n@ - newline
--
-- * @\\r@ - carriage return
--
-- * @\\t@ - horizontal tab
--
-- * @\\\\@ - backslash
--
-- * @\\\"@ - double quote
--
-- * @\\u@/xxxx/ - Unicode character from the basic multilingual
--   plane, encoded as four hexadecimal digits
--
-- * @\\u@/xxxx/@\\u@/xxxx/ - Unicode character from an astral plane,
--   as two hexadecimal-encoded UTF-16 surrogates

-- $interp
--
-- Strings support interpolation, so that you can dynamically
-- construct a string based on data in your configuration or the OS
-- environment.
--
-- If a string value contains the special sequence \"@$(foo)@\" (for
-- any name @foo@), then the name @foo@ will be looked up in the
-- configuration data and its value substituted.  If that name cannot
-- be found, it will be looked up in the OS environment.
--
-- For security reasons, it is an error for a string interpolation
-- fragment to contain a name that cannot be found in either the
-- current configuration or the environment.
--
-- To represent a single literal \"@$@\" character in a string, double
-- it: \"@$$@\".

-- $group
--
-- It is possible to group a number of directives together under a
-- single prefix:
--
-- > my-group
-- > {
-- >   a = 1
-- >
-- >   nested {
-- >     b = "yay!"
-- >   }
-- > }
--
-- The name of a group is used as a prefix for the items in the
-- group. For instance, the name \"@a@\" above can be found using
-- 'lookup' under the name \"@my-group.a@\", and \"@b@\" will be named
-- \"@my-group.nested.b@\".

-- $import
--
-- To import the contents of another configuration file, use the
-- @import@ directive.
--
-- > import "$(HOME)/etc/myapp.cfg"
--
-- It is an error for an @import@ directive to name a file that does
-- not exist, cannot be read, or contains errors.
--
-- If an @import@ appears inside a group, the group's naming prefix
-- will be applied to all of the names imported from the given
-- configuration file.
--
-- Supposing we have a file named \"@foo.cfg@\":
--
-- > bar = 1
--
-- And another file that imports it into a group:
--
-- > hi {
-- >   import "foo.cfg"
-- > }
--
-- This will result in a value named \"@hi.bar@\".
