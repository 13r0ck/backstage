// Built by `idris2 --build hello.ipkg` (codegen set in the Makefile).
// Importing it runs Idris's `main`, which registers `globalThis.idrisHandler`.
import "../build/exec/hello.js";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    return new Response(globalThis.idrisHandler(pathname), {
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
