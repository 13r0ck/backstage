||| Sending one message through Signal's chat server.
|||
||| A send fetches the recipient's pre-key bundles, encrypts the message for
||| each of their devices (`Signal.Wasm`), and submits the result. Every send
||| starts fresh sessions, so nothing is stored between sends.
module Signal.Api

import Cloudflare.Workers
import Data.List
import Data.String
import Datastar.Json
import Signal.Wasm

%default covering

||| What a send needs, from the Worker's secrets.
public export
record Config where
  constructor MkConfig
  bot    : Bot
  target : String

||| Reads the secrets `BOT_ACI`, `BOT_PASSWORD`, `BOT_IDENTITY_KEY`,
||| `BOT_REG_ID` and `TARGET_ACI`. Nothing if any is missing.
export
config : Env -> Maybe Config
config env = do
  aci <- getEnv "BOT_ACI" env
  password <- getEnv "BOT_PASSWORD" env
  key <- getEnv "BOT_IDENTITY_KEY" env
  reg <- getEnv "BOT_REG_ID" env >>= parsePositive
  target <- getEnv "TARGET_ACI" env
  pure (MkConfig (MkBot aci password (identityKey key) (cast {from = Integer} reg)) target)

||| chat.signal.org, through Signal's Fastly reflector (libsignal's
||| domain-fronting route). chat.signal.org itself presents a certificate from
||| Signal's private CA, which Workers' fetch rejects (HTTP 526); the reflector
||| has a public one. Fastly terminates TLS, so it sees request headers (the
||| bot's password) and metadata, but message content stays end-to-end
||| encrypted.
server : String
server = "https://reflector-signal.global.ssl.fastly.net/service"

%foreign "javascript:lambda:(s) => btoa(s)"
prim__btoa : String -> String

%foreign "javascript:lambda:() => Date.now()"
prim__now : PrimIO Double

||| The bot authenticates as its primary device (device 1).
headers : Config -> List (String, String)
headers c =
  [ ("authorization", "Basic " ++ prim__btoa (c.bot.aci ++ ".1:" ++ c.bot.password))
  , ("user-agent", "backstage")
  , ("x-signal-agent", "backstage")
  , ("content-type", "application/json")
  ]

field : String -> Json -> Maybe Json
field k (JObject kvs) = lookup k kvs
field _ _             = Nothing

int : Json -> Maybe Int32
int (JNumber d) = Just (cast d)
int _           = Nothing

||| The device IDs in a `GET /v2/keys` response.
export
deviceIds : String -> Either String (List Int32)
deviceIds body = do
  json <- parse body
  case field "devices" json of
    Just (JArray ds) => maybe (Left "bad device entry") Right (traverse (\d => field "deviceId" d >>= int) ds)
    _                => Left "no devices in key response"

failure : String -> FetchResponse -> String
failure what r = what ++ ": HTTP " ++ show r.status ++ (if r.body == "" then "" else " " ++ r.body)

||| Fetches the recipient's bundles and builds the `PUT /v1/messages` body.
messages : Config -> String -> Double -> Async String
messages c text ts = do
  keys <- fetch (MkFetchRequest GET (server ++ "/v2/keys/" ++ c.target ++ "/*") (headers c) Nothing)
  when (keys.status /= 200) $ throw (failure "fetching keys" keys)
  devices <- either throw pure (deviceIds keys.body)
  entries <- for devices $ \d => encrypt c.bot c.target d keys.body text ts >>= either throw pure
  pure $ "{\"messages\":[" ++ joinBy "," entries ++ "],\"timestamp\":" ++ show (cast {to = Integer} ts)
      ++ ",\"online\":false,\"urgent\":true}"

submit : Config -> String -> Async FetchResponse
submit c body = fetch (MkFetchRequest PUT (server ++ "/v1/messages/" ++ c.target) (headers c) (Just body))

||| Sends `text` to the configured recipient.
|||
||| If the server reports that our device list was wrong or stale (409/410),
||| refetches every bundle and tries once more.
export
send : Config -> String -> Async ()
send c text = do
  ts <- primIO prim__now
  r <- messages c text ts >>= submit c
  r <- if r.status == 409 || r.status == 410
          then messages c text ts >>= submit c
          else pure r
  when (r.status /= 200) $ throw (failure "sending" r)
