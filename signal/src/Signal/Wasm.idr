||| Bindings to signal-wasm (libsignal compiled to wasm), which the Worker
||| entry exposes as `globalThis.signalWasm`.
|||
||| Key material is opaque: Idris code can build an `IdentityKey` from the
||| secret that holds it and hand it to `encrypt`, but never inspect it.
module Signal.Wasm

%default total

||| The bot's identity private key (base64 of 32 bytes, as stored in the
||| `BOT_IDENTITY_KEY` secret).
export
data IdentityKey = MkIdentityKey String

export
identityKey : (base64 : String) -> IdentityKey
identityKey = MkIdentityKey

||| The sending account.
public export
record Bot where
  constructor MkBot
  aci            : String
  password       : String
  identity       : IdentityKey
  registrationId : Int32

-- signal-wasm throws its error message; return "1<result>" or "0<error>".
%foreign """
  javascript:lambda:(key, reg, bot, target, device, keys, text, ts) => {
    try {
      return "1" + globalThis.signalWasm.encrypt(key, Number(reg), bot, target, Number(device), keys, text, ts);
    } catch (e) {
      return "0" + String(e?.message ?? e);
    }
  }
  """
prim__encrypt : String -> Int32 -> String -> String -> Int32 -> String -> String -> Double -> PrimIO String

||| Encrypts `text` for one device of `target`, as a new session (there is no
||| stored state). `keys` is the body of `GET /v2/keys/{target}/*`.
||| Returns the JSON object for that device in `PUT /v1/messages`.
export
encrypt : HasIO io => Bot -> (target : String) -> (device : Int32) -> (keys : String)
       -> (text : String) -> (timestamp : Double) -> io (Either String String)
encrypt bot target device keys text ts = do
  let MkIdentityKey key = bot.identity
  r <- primIO $ prim__encrypt key bot.registrationId bot.aci target device keys text ts
  pure $ case strUncons r of
    Just ('1', json) => Right json
    Just (_, e)      => Left e
    Nothing          => Left "signal-wasm returned nothing"
