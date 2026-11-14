// Running the compiled Idris program registers its Worker (see Cloudflare.Workers.serve).
import "./build/exec/site.js";

export default globalThis.cloudflareWorker;
