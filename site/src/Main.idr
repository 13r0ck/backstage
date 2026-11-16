module Main

import Cloudflare.Workers
import Cloudflare.Workers.Datastar
import Datastar
import Datastar.SSE
import Data.Maybe
import Data.String
import Fixture
import Signal.Api
import Signal.Wasm

%default covering

name, count : Signal
name  = signal "name"
count = signal "count"

greeting : String -> Html
greeting n = p_ [id_ "greeting"] [text ("Hello, " ++ (if n == "" then "world" else n) ++ "!")]

sendStatus : String -> Html
sendStatus s = p_ [id_ "send-status"] [text s]

home : Response
home = page [title_ [] [text "backstage"]]
  [ main_ [dataSignals [(name, JString ""), (count, JNumber 0)]]
      [ h1_ [] [text "Hello from Idris2 on Cloudflare Workers"]
      , section_ []
          [ input_ [dataBind name, placeholder_ "Your name"]
          , button_ [dataOn Click (action GET "/greet")] [text "Greet"]
          , greeting ""
          ]
      , section_ []
          [ button_ [dataOn Click (action POST "/increment")] [text "+1"]
          , span_ [dataText (sig count)] [text "0"]
          ]
      , section_ []
          [ button_ [dataOn Click (action POST "/send")] [text "Send me a Signal message"]
          , sendStatus ""
          ]
      ]
  ]

withSignals : Request -> (Signals -> Response) -> Response
withSignals req k = either (respond BadRequest PlainText) k (readSignals req)

||| Sends the Signal message. Without the bot's secrets (previews don't get
||| them) it says so instead of failing.
send : Env -> Async Response
send env = case config env of
  Nothing => pure (events [patch (sendStatus "Signal is not configured on this deployment.")])
  Just c  => do
    r <- attempt (Signal.Api.send c "Hello from backstage!")
    pure (events [patch (sendStatus (either ("Sending failed: " ++) (const "Sent!") r))])

||| Encrypts with libsignal against a fixture bundle, without the network:
||| checks the wasm is loaded and working. Responds with the message type
||| (3: PreKeySignalMessage).
selftest : Async Response
selftest = do
  let bot = MkBot "9d0652a3-dcc3-4d11-975f-74d61598733f" "" (identityKey "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=") 1
  r <- encrypt bot "6fb6f1a5-3c1e-4b7c-8f4e-5d2a1b0c9e8d" 1 Fixture.keys "hello world" 1700000000000
  pure $ either (respond InternalServerError PlainText) (respond OK Json) r

routes : Env -> Request -> Async Response
routes env req = case (req.method, req.path) of
  (GET,  [])                     => pure home
  (GET,  ["greet"])              => pure $ withSignals req $ \ss =>
                                      events [patch (greeting (fromMaybe "" (getString name ss)))]
  (POST, ["increment"])          => pure $ withSignals req $ \ss =>
                                      events [setSignals [(count, JNumber (fromMaybe 0 (getNumber count ss) + 1))]]
  (POST, ["send"])               => send env
  (GET,  ["signal", "selftest"]) => selftest
  (_,    [])                     => pure methodNotAllowed
  _                              => pure notFound

main : IO ()
main = serveAsync routes
