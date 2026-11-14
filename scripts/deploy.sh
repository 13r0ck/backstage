#!/bin/sh
# Deploy (or delete) the Worker for a git branch.
#
# Each Worker is served at <worker name>.<account subdomain>.workers.dev:
#   main         -> Worker "backstage"         -> backstage.regal.workers.dev
#   other branch -> Worker "<slug>-backstage"  -> <slug>-backstage.regal.workers.dev
#
# Usage: scripts/deploy.sh deploy|delete <branch>
# Requires wrangler auth (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID).
set -eu

action=$1
branch=$2

if [ "$branch" = main ]; then
  name=backstage
else
  # DNS label: lowercase alphanumerics and '-', no leading/trailing '-'.
  # 53 chars keeps "<slug>-backstage" within the 63-char Worker name limit.
  slug=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' | cut -c1-53 | sed -e 's/^-//' -e 's/-$//')
  [ -n "$slug" ] || { echo "branch '$branch' has no usable characters" >&2; exit 1; }
  name=$slug-backstage
fi

case $action in
  deploy)
    make build
    wrangler deploy --name "$name"
    ;;
  delete)
    [ "$branch" != main ] || { echo "refusing to delete production" >&2; exit 1; }
    wrangler delete --name "$name" --force
    ;;
  *)
    echo "usage: $0 deploy|delete <branch>" >&2
    exit 2
    ;;
esac
