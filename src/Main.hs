{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where
-- Author: lvwenlong_lambda@qq.com
-- Last Modified:2016年03月05日 星期六 19时54分28秒 六
import Control.Monad
import Text.ParserCombinators.Parsec
import System.Posix.Files
import Data.Time.Clock
import Data.Time.LocalTime
import Data.Time.Calendar
import Data.List hiding(insert, lookup)
import Data.List.Split hiding(endBy)
import qualified Data.Map as Map
import Options.Generic
import Debug.Trace

data VimLogTime = VimLogTime {
    vimLogYear   :: Integer
  , vimLogMonth  :: Int
  , vimLogDay    :: Int
  , vimLogHour   :: Int
  , vimLogMinute :: Int
  , vimLogSecond :: Int
} deriving(Eq, Show)

data VimLogAction    = Create | Open | Write deriving(Eq, Show)
type VimLogGitBranch = String
type VimFileType     = String
data VimLog = VimLog {
    time       :: VimLogTime
  , action     :: VimLogAction
  , editedfile :: FilePath
  , filetype   :: VimFileType
  , gitbranch  :: Maybe VimLogGitBranch
} deriving(Eq)

secondOfDay :: VimLogTime -> Integer
secondOfDay t = let h = toInteger $ vimLogHour   t
                    m = toInteger $ vimLogMinute t
                    s = toInteger $ vimLogSecond t
                 in h * 3600 + m * 60 + s

dateToday :: IO String -- (year, month, day)
dateToday = liftM (map replace . showGregorian . utctDay) getCurrentTime
    where replace '-' = '/'
          replace  c   = c

logParser :: Parser VimLog
logParser = VimLog <$> (logTimeParser  <* delimiter)
                   <*> (actionParser   <* delimiter)
                   <*> (filePathParser <* delimiter)
                   <*> (filePathParser <* delimiter)
                   <*> branchParser
   where delimiter = char ';'

logTimeParser :: Parser VimLogTime
logTimeParser = VimLogTime <$> (read <$> many1   digit <* char '-') -- year
                           <*> (read <$> count 2 digit <* char '-') -- month
                           <*> (read <$> count 2 digit <* spaces)   -- day
                           <*> (read <$> count 2 digit <* char ':') -- hour
                           <*> (read <$> count 2 digit <* char ':') -- minute
                           <*> (read <$> count 2 digit)             -- second

fileTypeParser :: Parser VimFileType 
fileTypeParser = many1 (noneOf ";") 

actionParser :: Parser VimLogAction
actionParser = (Create <$ string "create")
           <|> (Open   <$ string "open")
           <|> (Write  <$ string "write")

filePathParser :: Parser FilePath
filePathParser = try quotedPath <|> many1 (noneOf ";\n\r")

quotedPath :: Parser FilePath
quotedPath = char '"' *> many1 quotedChar <* char '"'

quotedChar :: Parser Char
quotedChar = try ('"' <$ string "\\\"") <|>  noneOf "\"" <?> "fuck"

branchParser :: Parser (Maybe VimLogGitBranch)
branchParser = (Just <$> filePathParser) <|> (Nothing <$ string "")

eol :: Parser String 
eol = try (string "\n\r")
  <|> try (string "\r\n")
  <|> string "\r"
  <|> string "\n"
  <?> "end of line"

logFileParser :: Parser [VimLog]
logFileParser = logParser `endBy` eol


logMap :: [VimLog] -> Map.Map FilePath [(Integer, VimLogAction)]
logMap = foldr updateMap Map.empty
  where updateMap log map =
            let sec  = secondOfDay $ time log
                act  = action log
                file = editedfile log
                rec  = Map.lookup file map
             in case rec of
                  Nothing  -> Map.insert file [(sec, act)] map
                  Just rec -> Map.adjust ((sec, act):) file map

-- vim allow you to change the file type,
-- so it is possible that even with same file path
-- you get different file type
-- we use the last file type recorded
filetypeMap :: [VimLog] -> Map.Map FilePath VimFileType
filetypeMap logs = let names = map editedfile logs
                       types = map filetype logs
                    in Map.fromList $ zip names types

trans2 :: (a->a->b)->(c->a)->c->c->b
trans2 func cvt c1 c2 = func (cvt c1) (cvt c2)

duration :: Maybe Integer->[(Integer,VimLogAction)] -> Integer
duration maxInterval logs = sum $ filter (less maxInterval) durations
  where durations = concatMap (delta . map fst) splited
        splited   = split (keepDelimsL (whenElt ((/= Write) . snd))) sorted
        sorted    = sortBy (compare `trans2` fst) logs
        delta []  = []
        delta xs  = zipWith (-) (tail xs) xs
        less Nothing _   = True
        less (Just v) vv = vv < v

data CmdOptions = Today { dir :: String, maxInterval :: Maybe Integer }
                | File { file :: String, maxInterval :: Maybe Integer }
                deriving(Generic, Eq, Show)
instance ParseRecord CmdOptions

main :: IO ()
main = do
    opt   <- getRecord "Parse log file generated by https://github.com/Alaya-in-Matrix/vim-activity-log and record how long you have spent on vim"
    today <- dateToday
    (path, interv) <- return $ case opt of
          Today dir interval  -> (dir ++ "/" ++ today ++ ".log", interval)
          File  file interval -> (file, interval)
    exist  <- fileExist path
    if not exist
       then putStrLn "No vim action found"
       else do parsed  <- parseFromFile logFileParser path 
               case parsed of
                  Left errMsg -> print errMsg
                  Right val   -> summary interv val

summary :: Maybe Integer -> [VimLog] -> IO ()
summary maxInterval val = 
  let logmap = logMap $ reverse val
      ftmp   = filetypeMap val
      durmap = Map.map (duration maxInterval) logmap
      filetypeTime = Map.toList $ getFileTypeTime ftmp durmap 
   in do mapM_ (putStrLn.showLog) $ sortBy (flip compare `trans2` snd) filetypeTime
         putStrLn "============================="

showLog :: (VimFileType,Integer) -> String
showLog (ft, sec) = ft ++ ": " ++ show (timeToTimeOfDay.secondsToDiffTime $ sec)

getFileTypeTime :: Map.Map FilePath VimFileType 
                -> Map.Map FilePath Integer 
                -> Map.Map VimFileType Integer
getFileTypeTime typeLog fileLog = Map.fromListWith (+) typeLogList
  where typeLogList          = map convertType $ Map.toList fileLog
        convertType (name,t) =
          case Map.lookup name typeLog of
            Nothing -> error $ "fail to find file type for " ++ name
            Just v  -> (v,t)
