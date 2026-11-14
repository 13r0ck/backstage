// Running the compiled Idris program registers its Worker (see Cloudflare.Workers.serve).
import "./build/exec/site.js";

const worker = globalThis.cloudflareWorker;

export default {
  // Tags responses with the deployed commit (set by backstage deploy).
  async fetch(request, env) {
    const response = await worker.fetch(request);
    response.headers.set("x-commit", env.COMMIT ?? "dev");
    return response;
  },
};
