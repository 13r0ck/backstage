module Main

import Cloudflare.Workers
import Cloudflare.Workers.Datastar
import Datastar
import Datastar.SSE
import Data.Maybe

%default covering

name, count : Signal
name  = signal "name"
count = signal "count"

greeting : String -> Html
greeting n = p_ [id_ "greeting"] [text ("Hello, " ++ (if n == "" then "world" else n) ++ "!")]

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
      ]
  ]

withSignals : Request -> (Signals -> Response) -> Response
withSignals req k = either (respond BadRequest PlainText) k (readSignals req)

routes : Request -> Response
routes req = case (req.method, req.path) of
  (GET,  [])            => home
  (GET,  ["greet"])     => withSignals req $ \ss =>
                             events [patch (greeting (fromMaybe "" (getString name ss)))]
  (POST, ["increment"]) => withSignals req $ \ss =>
                             events [setSignals [(count, JNumber (fromMaybe 0 (getNumber count ss) + 1))]]
  (_,    [])            => methodNotAllowed
  _                     => notFound

main : IO ()
main = serve (pure . routes)
