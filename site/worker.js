// libsignal, compiled to wasm (signal-wasm/; copied here by backstage build).
// Signal.Wasm calls it through globalThis.signalWasm.
import wasm from "./build/signal/signal_wasm_bg.wasm";
import { initSync, encrypt } from "./build/signal/signal_wasm.js";
// Running the compiled Idris program registers its Worker (see Cloudflare.Workers.serveAsync).
import "./build/exec/site.js";

initSync({ module: wasm });
globalThis.signalWasm = { encrypt };

const worker = globalThis.cloudflareWorker;

export default {
  // Tags responses with the deployed commit (set by backstage deploy).
  async fetch(request, env) {
    const response = await worker.fetch(request, env);
    response.headers.set("x-commit", env.COMMIT ?? "dev");
    return response;
  },
};
