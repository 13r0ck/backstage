# Agent guide

An Idris2 site compiled to JavaScript and served from Cloudflare Workers.

## Layout

- `cloudflare-workers/`: Idris2 library with typed Workers requests/responses (`Cloudflare.Workers`).
- `datastar/`: pure Idris2 library for Datastar: escaped HTML, JSON, signals, SSE events.
- `cloudflare-workers-datastar/`: glue between the two.
- `site/`: the website (`src/Main.idr`); `worker.js` is the Worker entry that loads the compiled `build/exec/site.js`.
- `tools/backstage/main.zig`: the build/deploy CLI (Zig 0.17; check its std library before using an API, it changed a lot recently).
- `flake.nix`: builds every package; `nix develop` is the dev environment.

## Setup

Work inside `nix develop`. Entering it builds the libraries, puts `idris2`, `backstage` and `wrangler` on `PATH`, and enables the Git hooks in `.githooks/`.

The flake only sees Git-tracked files, and the libraries are built when the shell starts. After changing anything in a library package, `git add` it and re-enter `nix develop` before building the site.

## Build and run locally

- `backstage build` compiles the site.
- `backstage dev` builds and serves it at http://localhost:8787 (`wrangler dev`).

## Publish a dev branch (seconds)

Dev branches deploy from your own machine on `git push`, to the **dev** Cloudflare account:

1. Work on a branch other than `main`, and commit. The post-commit hook builds the site in the background and records which commit it built.
2. `git push origin <branch>`. The pre-push hook uploads that build (about 1 s) before the push is sent; it compiles first if the background build isn't for the pushed commit.
3. The preview is live at `https://<branch-slug>.jumble-bust-nugget.workers.dev`. The slug is the branch name lowercased, with every run of other characters turned into `-`.

Check which commit a preview serves through the `x-commit` header (use GET; HEAD returns 405):

```sh
curl -s -D - -o /dev/null https://<branch-slug>.jumble-bust-nugget.workers.dev/ | grep -i x-commit
```

Details:

- The hook only deploys when the working tree is clean and its HEAD is the pushed commit; otherwise it prints why and skips. It never blocks a push.
- It uses only the dev account's credentials, `CLOUDFLARE_DEV_API_TOKEN` and `CLOUDFLARE_DEV_ACCOUNT_ID`, read from the environment, a gitignored `.env`, or `~/.config/backstage/.env`. If they're missing it skips. Don't create credential files inside the repo; never print or commit tokens.
- Without a pull request, CI doesn't deploy the branch and nothing deletes its preview. Open a PR to get the CI deploy and automatic cleanup when it closes.

## Release to production (trusted pipeline only)

Production is the Worker `backstage` on the production Cloudflare account, served at https://backstage.regal.workers.dev.

- Only GitHub Actions deploys it, on pushes to `main`. Get changes there through a pull request; the repository only allows rebase merges, so keep PRs to cohesive commits.
- Never deploy production from a local machine, and never ask for or use the production credentials (`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`). Developer machines only hold the dev token by design.
- After merging, CI takes about 14 s from push to live. Confirm with the `x-commit` header on the production URL.

## CI

`.github/workflows/deploy.yml`: pull requests deploy previews to the dev account, pushes to `main` deploy production, and closing a PR deletes its preview.

CI doesn't install Nix on a normal run. `.github/actions/tools` restores the flake's `ci-tools` package (idris2 wrapped to find our libraries, plus `backstage`) from the GitHub Actions cache into `/nix/store`. Changes to `flake.nix`, `flake.lock`, the library packages or `tools/` cause a one-time cache miss (about 60 s) that installs Nix, rebuilds `ci-tools` and saves it.

`backstage` is compiled for baseline x86-64 because the cached binary runs on other machines; keep `-mcpu=baseline` in `flake.nix`.
