||| Just enough JSON for Datastar signals: a value type, an encoder, and a
||| parser for the signal payloads the browser sends.
module Datastar.Json

import Data.List
import Data.String

%default total

public export
data Json
  = JNull
  | JBool Bool
  | JNumber Double
  | JString String
  | JArray (List Json)
  | JObject (List (String, Json))

hexDigit : Int -> Char
hexDigit n = if n < 10 then chr (ord '0' + n) else chr (ord 'a' + n - 10)

escapeChar : Char -> List Char
escapeChar '"'  = ['\\', '"']
escapeChar '\\' = ['\\', '\\']
escapeChar '\n' = ['\\', 'n']
escapeChar '\r' = ['\\', 'r']
escapeChar '\t' = ['\\', 't']
escapeChar c =
  if ord c < 0x20
     then ['\\', 'u', '0', '0', hexDigit (ord c `div` 16), hexDigit (ord c `mod` 16)]
     else [c]

export
quote : String -> String
quote s = pack ('"' :: concatMap escapeChar (unpack s) ++ ['"'])

||| Whole numbers print without a trailing ".0".
showNumber : Double -> String
showNumber d =
  let i = the Integer (cast d) in
  if cast i == d then show i else show d

export
encode : Json -> String
encode JNull        = "null"
encode (JBool b)    = if b then "true" else "false"
encode (JNumber d)  = showNumber d
encode (JString s)  = quote s
encode (JArray xs)  = "[" ++ joinBy "," (encodeAll xs) ++ "]"
  where
    encodeAll : List Json -> List String
    encodeAll []        = []
    encodeAll (x :: xs) = encode x :: encodeAll xs
encode (JObject kvs) = "{" ++ joinBy "," (encodeFields kvs) ++ "}"
  where
    encodeFields : List (String, Json) -> List String
    encodeFields []             = []
    encodeFields ((k, v) :: kvs) = (quote k ++ ":" ++ encode v) :: encodeFields kvs

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

Parser : Type -> Type
Parser a = List Char -> Either String (a, List Char)

ws : List Char -> List Char
ws (c :: cs) = if isSpace c then ws cs else c :: cs
ws []        = []

hexValue : Char -> Maybe Int
hexValue c =
  if isDigit c then Just (ord c - ord '0')
  else if c >= 'a' && c <= 'f' then Just (ord c - ord 'a' + 10)
  else if c >= 'A' && c <= 'F' then Just (ord c - ord 'A' + 10)
  else Nothing

parseString : List Char -> Parser String
parseString acc ('"' :: cs) = Right (pack (reverse acc), cs)
parseString acc ('\\' :: e :: cs) = case e of
  '"'  => parseString ('"' :: acc) cs
  '\\' => parseString ('\\' :: acc) cs
  '/'  => parseString ('/' :: acc) cs
  'b'  => parseString ('\b' :: acc) cs
  'f'  => parseString ('\f' :: acc) cs
  'n'  => parseString ('\n' :: acc) cs
  'r'  => parseString ('\r' :: acc) cs
  't'  => parseString ('\t' :: acc) cs
  'u'  => case cs of
    (a :: b :: c :: d :: rest) =>
      case traverse hexValue [a, b, c, d] of
        Just [w, x, y, z] => parseString (chr (((w * 16 + x) * 16 + y) * 16 + z) :: acc) rest
        _ => Left "bad \\u escape"
    _ => Left "bad \\u escape"
  _ => Left "bad escape"
parseString acc (c :: cs) = parseString (c :: acc) cs
parseString _   [] = Left "unterminated string"

isNumberChar : Char -> Bool
isNumberChar c = isDigit c || elem c (unpack "+-.eE")

mutual
  covering
  value : Parser Json
  value cs = case ws cs of
    ('n' :: 'u' :: 'l' :: 'l' :: r)        => Right (JNull, r)
    ('t' :: 'r' :: 'u' :: 'e' :: r)        => Right (JBool True, r)
    ('f' :: 'a' :: 'l' :: 's' :: 'e' :: r) => Right (JBool False, r)
    ('"' :: r) => mapFst JString <$> parseString [] r
    ('[' :: r) => case ws r of
      (']' :: r') => Right (JArray [], r')
      _           => mapFst JArray <$> elements [] r
    ('{' :: r) => case ws r of
      ('}' :: r') => Right (JObject [], r')
      _           => mapFst JObject <$> fields [] r
    r@(c :: _) =>
      if isNumberChar c
         then let (num, rest) = span isNumberChar r in
              maybe (Left "bad number") (\d => Right (JNumber d, rest)) (parseDouble (pack num))
         else Left ("unexpected " ++ singleton c)
    [] => Left "unexpected end of input"

  covering
  elements : List Json -> Parser (List Json)
  elements acc cs = do
    (v, r) <- value cs
    case ws r of
      (',' :: r') => elements (v :: acc) r'
      (']' :: r') => Right (reverse (v :: acc), r')
      _           => Left "expected , or ]"

  covering
  fields : List (String, Json) -> Parser (List (String, Json))
  fields acc cs = case ws cs of
    ('"' :: r) => do
      (k, r1) <- parseString [] r
      case ws r1 of
        (':' :: r2) => do
          (v, r3) <- value r2
          case ws r3 of
            (',' :: r4) => fields ((k, v) :: acc) r4
            ('}' :: r4) => Right (reverse ((k, v) :: acc), r4)
            _           => Left "expected , or }"
        _ => Left "expected :"
    _ => Left "expected object key"

export covering
parse : String -> Either String Json
parse s = do
  (v, rest) <- value (unpack s)
  case ws rest of
    [] => Right v
    _  => Left "trailing input"
