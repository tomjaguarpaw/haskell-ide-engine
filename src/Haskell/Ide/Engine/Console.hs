{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Haskell.Ide.Engine.Console where

import           Control.Applicative
import           Control.Concurrent
import           Control.Monad.IO.Class
import           Data.Attoparsec.Text
import qualified Data.Map as Map
import           Data.Monoid
import qualified Data.Text as T
import           Haskell.Ide.Engine.BasePlugin
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.Types
import           System.Console.Haskeline

-- ---------------------------------------------------------------------

data ReplEnv = ReplEnv
      {
      } deriving (Show)

emptyEnv :: ReplEnv
emptyEnv = ReplEnv

-- ---------------------------------------------------------------------

consoleListener :: Plugins -> Chan ChannelRequest -> IO ()
consoleListener plugins cin = do
  cout <- newChan :: IO (Chan ChannelResponse)
  let
    startLoop :: ReplEnv -> Int -> InputT IO ()
    startLoop env cid = do
      outputStrLn $ "HIE version " ++ version
      outputStrLn "enter '?' for help"
      loop env cid

    loop :: ReplEnv -> Int -> InputT IO ()
    loop env cid = do
        minput <- getInputLine "HIE> "
        case fmap T.pack minput of
            Nothing -> return ()
            Just "quit" -> return ()
            Just cmdArg -> do
              let
                req = case T.words cmdArg of
                  [] -> Left $ "empty command"
                  ["?"] -> Left (helpStr plugins)
                  (cmdStr:ps) -> case Map.lookup cmdStr (replPluginInfo plugins) of
                                  Nothing -> Left $ "unrecognised command:" <> cmdStr
                                  Just (plugin,cmd) -> Right $ (plugin,IdeRequest (cmdName $ cmdDesc cmd) (convertToParams (cmdDesc cmd) ps))
              case req of
                Left err -> outputStrLn (T.unpack err)
                Right (plugin,reqVal) -> do
                  liftIO $ writeChan cin (CReq plugin cid reqVal cout)
                  rsp <- liftIO $ readChan cout
                  outputStrLn $ show (coutResp rsp)
              loop env (cid + 1)

  runInputT defaultSettings (startLoop emptyEnv 1)

-- ---------------------------------------------------------------------

helpStr :: Plugins -> T.Text
helpStr plugins = T.unlines $
  [ "HIE Help"
  , ""
  , "Invoke a plugin command by giving the plugin name, a colon, then the command"
  , "  e.g. HIE> base:plugins"
  , ""
  ] ++ pluginHelp plugins

-- ---------------------------------------------------------------------

pluginHelp :: Plugins -> [T.Text]
pluginHelp plugins = concatMap (\(k,v) -> descriptorHelp k v) $ Map.toList plugins

descriptorHelp :: PluginId -> PluginDescriptor -> [T.Text]
descriptorHelp pn cd = ["Plugin '" <> pn <> "'"] ++ r
  where
    descriptors = map cmdDesc (pdCommands cd)
    r = concatMap describeDescriptor descriptors

describeDescriptor :: CommandDescriptor -> [T.Text]
describeDescriptor d =
  [ "  command '" <> (cmdName d) <> "'"
  , "    " <> cmdUiDescription d
  ]

-- ---------------------------------------------------------------------

convertToParams :: CommandDescriptor -> [T.Text] -> Map.Map T.Text ParamVal
convertToParams cmd ss = Map.fromList $ map (\(k,v) -> (k,convertParam k v)) $  map splitOnColon ss
  where
    possibleParams = cmdAdditionalParams cmd ++ (concatMap contextMapping $ cmdContexts cmd)
    possibles = Map.fromList $ map (\pd -> (pName pd,pd)) possibleParams
    convertParam pn str =
      case Map.lookup pn possibles of
        Nothing -> ParamText str -- TODO: should this be an error of some kind
        Just p -> case pType p of
          PtText -> ParamText str
          PtFile -> ParamFile str
          PtPos  -> case parseOnly parsePos str of
            Left err -> ParamText str -- TODO: should this be an error of some kind
            Right pos -> ParamPos pos

parseInt :: Parser Int
parseInt = do
  str <- many1 digit
  return $ read str

parsePos :: Parser Pos
parsePos = do
  char '('
  r <- parseInt
  char ','
  c <- parseInt
  char ')'
  return (r,c)

-- ---------------------------------------------------------------------

-- |Split a string of the form "first:rest" into ("first","rest")
splitOnColon :: T.Text -> (T.Text,T.Text)
splitOnColon "" = ("","")
splitOnColon s = (first,second)
  where
    (first,rest) = T.break (==':') s
    second = case rest of
      "" -> ""
      _ -> T.tail rest

-- ---------------------------------------------------------------------
