module Main

-- The Worker entry (worker/index.js) imports the compiled output, which runs
-- `main`. `main` hands Idris's request handler to JavaScript through this FFI
-- call; the Worker's `fetch` then calls it with the request path.
%foreign "javascript:lambda:(h) => { globalThis.idrisHandler = h }"
prim__registerHandler : (String -> String) -> PrimIO ()

registerHandler : HasIO io => (String -> String) -> io ()
registerHandler h = primIO (prim__registerHandler h)

handle : String -> String
handle path = "Hello, world! (from Idris2, path: " ++ path ++ ")"

main : IO ()
main = registerHandler handle
