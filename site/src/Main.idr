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

-- No quotes or angle brackets, so the text escaping can't alter it.
stylesheet : String
stylesheet = """
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         font-family: system-ui, sans-serif; color: #f5f3ff;
         background: linear-gradient(135deg, #0f766e, #1d4ed8); }
  main { background: rgb(0 0 0 / 0.25); padding: 2rem 3rem; border-radius: 1rem; }
  button, input { font: inherit; padding: 0.4rem 0.8rem; border-radius: 0.5rem; border: 0; }
  section { margin-top: 1rem; display: flex; gap: 0.5rem; align-items: center; }
  """

home : Response
home = page [title_ [] [text "backstage"], style_ [] [text stylesheet]]
  [ main_ [dataSignals [(name, JString ""), (count, JNumber 0)]]
      [ h1_ [] [text "Hello from Idris2, deployed on push"]
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
