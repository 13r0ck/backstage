||| Glue between `Cloudflare.Workers` and `Datastar`.
module Cloudflare.Workers.Datastar

import Cloudflare.Workers
import Datastar
import Datastar.SSE

%default total

||| A Datastar SSE response. The stream ends after these events, which
||| Datastar treats as a completed request.
export
events : List Event -> Response
events es = withHeader "cache-control" "no-cache" (respond OK EventStream (renderEvents es))

||| A full HTML page with the Datastar client loaded.
export
page : (head : List Html) -> (body : List Html) -> Response
page hd bd = html (document (meta_ [charset_ "utf-8"] :: clientScript :: hd) bd)

||| The signals Datastar sent: the `datastar` query parameter for GET,
||| otherwise the JSON body.
export covering
readSignals : Request -> Either String Signals
readSignals req = do
  src <- case req.method of
    GET => maybe (Left "missing datastar query parameter") Right (queryParam "datastar" req)
    _   => Right req.body
  json <- parse src
  maybe (Left "signals must be a JSON object") Right (fromJson json)
