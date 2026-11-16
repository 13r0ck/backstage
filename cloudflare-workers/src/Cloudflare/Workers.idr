||| Write Cloudflare Workers as typed Idris2 handlers.
|||
||| A Worker is a `Handler`: a function from a fully-read `Request` to a
||| `Response`. `serve` publishes it as `globalThis.cloudflareWorker`, an
||| ES-module-style Worker object, so the Worker entry file only needs:
|||
|||     import "./build/exec/<app>.js";
|||     export default globalThis.cloudflareWorker;
|||
||| The request body is read before the handler runs, so handlers are plain
||| `IO` and never see JavaScript promises.
|||
||| Handlers that call other services use `serveAsync` instead: they run in
||| `Async`, can make outbound requests with `fetch`, and read the Worker's
||| bindings (secrets, vars) from its `Env`. The Worker entry then passes
||| `env` along: `globalThis.cloudflareWorker.fetch(request, env)`.
module Cloudflare.Workers

import Data.List
import Data.List1
import Data.Maybe
import Data.String

%default total

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

public export
data Method = GET | HEAD | POST | PUT | DELETE | PATCH | OPTIONS | Other String

export
parseMethod : String -> Method
parseMethod "GET"     = GET
parseMethod "HEAD"    = HEAD
parseMethod "POST"    = POST
parseMethod "PUT"     = PUT
parseMethod "DELETE"  = DELETE
parseMethod "PATCH"   = PATCH
parseMethod "OPTIONS" = OPTIONS
parseMethod other     = Other other

public export
record Request where
  constructor MkRequest
  method  : Method
  ||| Percent-decoded, non-empty path segments:
  ||| "/hello/big%20world/" is ["hello", "big world"].
  path    : List String
  ||| Decoded query parameters, in order.
  query   : List (String, String)
  ||| Header names are lowercase.
  headers : List (String, String)
  body    : String

export
header : String -> Request -> Maybe String
header name req = lookup (toLower name) req.headers

export
queryParam : String -> Request -> Maybe String
queryParam name req = lookup name req.query

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

public export
data Status
  = OK | Created | Accepted | NoContent
  | MovedPermanently | Found | SeeOther | NotModified
  | TemporaryRedirect | PermanentRedirect
  | BadRequest | Unauthorized | Forbidden | NotFound | MethodNotAllowed
  | Conflict | UnprocessableContent | TooManyRequests
  | InternalServerError | NotImplemented | ServiceUnavailable

export
statusCode : Status -> Int32
statusCode OK                   = 200
statusCode Created              = 201
statusCode Accepted             = 202
statusCode NoContent            = 204
statusCode MovedPermanently     = 301
statusCode Found                = 302
statusCode SeeOther             = 303
statusCode NotModified          = 304
statusCode TemporaryRedirect    = 307
statusCode PermanentRedirect    = 308
statusCode BadRequest           = 400
statusCode Unauthorized         = 401
statusCode Forbidden            = 403
statusCode NotFound             = 404
statusCode MethodNotAllowed     = 405
statusCode Conflict             = 409
statusCode UnprocessableContent = 422
statusCode TooManyRequests      = 429
statusCode InternalServerError  = 500
statusCode NotImplemented       = 501
statusCode ServiceUnavailable   = 503

||| Statuses the Fetch API allows a body for (everything but 204 and 304).
public export
allowsBody : Status -> Bool
allowsBody NoContent   = False
allowsBody NotModified = False
allowsBody _           = True

public export
isRedirect : Status -> Bool
isRedirect MovedPermanently  = True
isRedirect Found             = True
isRedirect SeeOther          = True
isRedirect TemporaryRedirect = True
isRedirect PermanentRedirect = True
isRedirect _                 = False

public export
data ContentType = PlainText | Html | Json | EventStream | Custom String

export
mimeType : ContentType -> String
mimeType PlainText   = "text/plain; charset=utf-8"
mimeType Html        = "text/html; charset=utf-8"
mimeType Json        = "application/json"
mimeType EventStream = "text/event-stream"
mimeType (Custom t)  = t

||| Abstract: build one with `respond`, `empty` or `redirect`, which check at
||| compile time that the status may (or may not) carry a body. The content
||| type always comes from the body, so it can't disagree with it.
export
record Response where
  constructor MkResponse
  status  : Status
  headers : List (String, String)
  body    : Maybe (ContentType, String)

||| A response with a body. `respond NoContent ...` does not typecheck.
export
respond : (s : Status) -> {auto 0 ok : allowsBody s = True} -> ContentType -> String -> Response
respond s ct b = MkResponse s [] (Just (ct, b))

||| A response without a body.
export
empty : Status -> Response
empty s = MkResponse s [] Nothing

||| `redirect SeeOther "/"`. Only redirect statuses typecheck.
export
redirect : (s : Status) -> {auto 0 ok : isRedirect s = True} -> (location : String) -> Response
redirect s location = MkResponse s [("location", location)] Nothing

export
text : String -> Response
text = respond OK PlainText

export
html : String -> Response
html = respond OK Html

export
notFound : Response
notFound = respond NotFound PlainText "Not Found"

export
methodNotAllowed : Response
methodNotAllowed = respond MethodNotAllowed PlainText "Method Not Allowed"

||| Adds a header. Use the body's `ContentType` rather than a content-type header.
export
withHeader : String -> String -> Response -> Response
withHeader name value = { headers $= (++ [(toLower name, value)]) }

--------------------------------------------------------------------------------
-- Serving
--------------------------------------------------------------------------------

public export
Handler : Type
Handler = Request -> IO Response

-- JavaScript side: the incoming request, pre-read into a plain object
-- { method, pathname: [segment], body, headers: [[k, v]], query: [[k, v]] }.

%foreign "javascript:lambda:(o, k) => o[k]"
prim__field : AnyPtr -> String -> String

%foreign "javascript:lambda:(o, k) => o[k].length"
prim__count : AnyPtr -> String -> Int32

%foreign "javascript:lambda:(o, k, i) => o[k][Number(i)]"
prim__item : AnyPtr -> String -> Int32 -> String

%foreign "javascript:lambda:(o, k, i, j) => o[k][Number(i)][Number(j)]"
prim__entry : AnyPtr -> String -> Int32 -> Int32 -> String

%foreign "javascript:lambda:() => new Headers()"
prim__newHeaders : PrimIO AnyPtr

%foreign "javascript:lambda:(hs, k, v) => hs.append(k, v)"
prim__appendHeader : AnyPtr -> String -> String -> PrimIO ()

%foreign "javascript:lambda:(status, hs) => new Response(null, { status: Number(status), headers: hs })"
prim__emptyResponse : Int32 -> AnyPtr -> PrimIO AnyPtr

%foreign "javascript:lambda:(status, hs, body) => new Response(body, { status: Number(status), headers: hs })"
prim__bodyResponse : Int32 -> AnyPtr -> String -> PrimIO AnyPtr

%foreign """
  javascript:lambda:(h) => {
    const decode = (s) => { try { return decodeURIComponent(s) } catch { return s } };
    globalThis.cloudflareWorker = {
      async fetch(req) {
        const url = new URL(req.url);
        const o = {
          method: req.method,
          path: url.pathname.split("/").filter((s) => s !== "").map(decode),
          body: await req.text(),
          headers: [...req.headers],
          query: [...url.searchParams],
        };
        return h(o)();
      },
    };
  }
  """
prim__serve : (AnyPtr -> PrimIO AnyPtr) -> PrimIO ()

indices : Int32 -> List Int32
indices n = if n <= 0 then [] else map cast [0 .. cast {to = Integer} n - 1]

fromJS : AnyPtr -> Request
fromJS o = MkRequest
  { method  = parseMethod (prim__field o "method")
  , path    = map (prim__item o "path") (indices (prim__count o "path"))
  , query   = entries "query"
  , headers = entries "headers"
  , body    = prim__field o "body"
  }
  where
    entries : String -> List (String, String)
    entries k = map (\i => (prim__entry o k i 0, prim__entry o k i 1)) (indices (prim__count o k))

toJS : Response -> IO AnyPtr
toJS r = do
  hs <- primIO prim__newHeaders
  for_ r.headers $ \(k, v) => primIO (prim__appendHeader hs k v)
  case r.body of
    Nothing      => primIO $ prim__emptyResponse (statusCode r.status) hs
    Just (ct, b) => do
      primIO (prim__appendHeader hs "content-type" (mimeType ct))
      primIO $ prim__bodyResponse (statusCode r.status) hs b

||| Publish `h` as this script's Worker. Call it from `main`.
export
serve : Handler -> IO ()
serve h = primIO $ prim__serve $ \o => toPrim (h (fromJS o) >>= toJS)

--------------------------------------------------------------------------------
-- Async handlers
--------------------------------------------------------------------------------

||| An asynchronous computation: given a callback for its result (or an
||| error message), starts and eventually calls it exactly once. This wraps
||| JavaScript promises in plain callbacks, which Idris2's JavaScript
||| backend supports, so no Promise ever crosses into Idris.
export
record Async a where
  constructor MkAsync
  start : (Either String a -> IO ()) -> IO ()

export
Functor Async where
  map f (MkAsync s) = MkAsync $ \k => s (k . map f)

export
Applicative Async where
  pure x = MkAsync $ \k => k (Right x)
  MkAsync sf <*> MkAsync sx = MkAsync $ \k =>
    sf $ either (k . Left) (\f => sx (k . map f))

export
Monad Async where
  MkAsync s >>= f = MkAsync $ \k =>
    s $ either (k . Left) (\x => (f x).start k)

export
HasIO Async where
  liftIO io = MkAsync $ \k => io >>= k . Right

||| Fails the computation; the rest of it doesn't run.
export
throw : String -> Async a
throw e = MkAsync $ \k => k (Left e)

||| Runs `a`, giving its error (if any) to the caller instead of failing.
export
attempt : Async a -> Async (Either String a)
attempt (MkAsync s) = MkAsync $ \k => s (k . Right)

||| The Worker's bindings: secrets, vars and the like.
export
data Env = MkEnv AnyPtr

%foreign "javascript:lambda:(env, k) => typeof env?.[k] === 'string' ? 1 : 0"
prim__hasString : AnyPtr -> String -> Int32

%foreign "javascript:lambda:(env, k) => env[k]"
prim__getString : AnyPtr -> String -> String

||| A string binding (a secret or plain-text var), if it is set.
export
getEnv : String -> Env -> Maybe String
getEnv k (MkEnv e) = if prim__hasString e k == 1 then Just (prim__getString e k) else Nothing

||| An outbound HTTP request, for `fetch`.
public export
record FetchRequest where
  constructor MkFetchRequest
  method  : Method
  url     : String
  headers : List (String, String)
  body    : Maybe String

||| A `GET` with no headers.
export
get : String -> FetchRequest
get url = MkFetchRequest GET url [] Nothing

||| The response to a `fetch`, body fully read.
public export
record FetchResponse where
  constructor MkFetchResponse
  status  : Int
  ||| Header names are lowercase.
  headers : List (String, String)
  body    : String

export
methodName : Method -> String
methodName GET       = "GET"
methodName HEAD      = "HEAD"
methodName POST      = "POST"
methodName PUT       = "PUT"
methodName DELETE    = "DELETE"
methodName PATCH     = "PATCH"
methodName OPTIONS   = "OPTIONS"
methodName (Other m) = m

-- Calls ok with { status, headers: [[k, v]], body } or err with a message.
%foreign """
  javascript:lambda:(method, url, hs, hasBody, body, ok, err) => {
    fetch(url, { method, headers: hs, body: Number(hasBody) ? body : undefined })
      .then(async (r) => ({ status: r.status, headers: [...r.headers], body: await r.text() }))
      .then((o) => ok(o)(), (e) => err(String(e?.message ?? e))())
  }
  """
prim__fetch : String -> String -> AnyPtr -> Int32 -> String
           -> (AnyPtr -> PrimIO ()) -> (String -> PrimIO ()) -> PrimIO ()

%foreign "javascript:lambda:(o) => Number(o.status)"
prim__status : AnyPtr -> Int

||| Makes an outbound HTTP request. Fails only if no response arrived (a
||| network error); HTTP error statuses are ordinary responses.
export
fetch : FetchRequest -> Async FetchResponse
fetch r = MkAsync $ \k => do
  hs <- primIO prim__newHeaders
  for_ r.headers $ \(n, v) => primIO (prim__appendHeader hs n v)
  primIO $ prim__fetch (methodName r.method) r.url hs
    (if isJust r.body then 1 else 0) (fromMaybe "" r.body)
    (\o => toPrim (k (Right (response o))))
    (\e => toPrim (k (Left e)))
  where
    response : AnyPtr -> FetchResponse
    response o = MkFetchResponse
      { status  = prim__status o
      , headers = map (\i => (prim__entry o "headers" i 0, prim__entry o "headers" i 1))
                      (indices (prim__count o "headers"))
      , body    = prim__field o "body"
      }

public export
AsyncHandler : Type
AsyncHandler = Env -> Request -> Async Response

%foreign "javascript:lambda:(resolve, r) => resolve(r)"
prim__resolve : AnyPtr -> AnyPtr -> PrimIO ()

%foreign """
  javascript:lambda:(h) => {
    const decode = (s) => { try { return decodeURIComponent(s) } catch { return s } };
    globalThis.cloudflareWorker = {
      async fetch(req, env) {
        const url = new URL(req.url);
        const o = {
          method: req.method,
          path: url.pathname.split("/").filter((s) => s !== "").map(decode),
          body: await req.text(),
          headers: [...req.headers],
          query: [...url.searchParams],
        };
        return new Promise((resolve) => h(o)(env ?? {})(resolve)());
      },
    };
  }
  """
prim__serveAsync : (AnyPtr -> AnyPtr -> AnyPtr -> PrimIO ()) -> PrimIO ()

||| Publish `h` as this script's Worker, like `serve` but asynchronous.
||| If `h` fails, the Worker responds 500 with the error message.
export
serveAsync : AsyncHandler -> IO ()
serveAsync h = primIO $ prim__serveAsync $ \o, env, resolve => toPrim $
  (h (MkEnv env) (fromJS o)).start $ \result => do
    r <- toJS (either (respond InternalServerError PlainText) id result)
    primIO (prim__resolve resolve r)
