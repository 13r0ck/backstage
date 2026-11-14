#!/bin/sh
# Deploy (or delete) the Worker for a git branch.
#
#   main         -> Worker "backstage",          served at $BASE_DOMAIN
#   other branch -> Worker "backstage-<slug>",   served at <slug>.$BASE_DOMAIN
#
# Usage: scripts/deploy.sh deploy|delete <branch>
# Requires BASE_DOMAIN (a zone on the Cloudflare account) and wrangler auth.
set -eu

action=$1
branch=$2
: "${BASE_DOMAIN:?set BASE_DOMAIN, e.g. blah.com}"

if [ "$branch" = main ]; then
  name=backstage
  domain=$BASE_DOMAIN
else
  # DNS label: lowercase alphanumerics and '-', no leading/trailing '-'.
  # 53 chars keeps "backstage-<slug>" within the 63-char Worker name limit.
  slug=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' | cut -c1-53 | sed -e 's/^-//' -e 's/-$//')
  [ -n "$slug" ] || { echo "branch '$branch' has no usable characters" >&2; exit 1; }
  name=backstage-$slug
  domain=$slug.$BASE_DOMAIN
fi

case $action in
  deploy)
    make build
    wrangler deploy --name "$name" --domain "$domain"
    echo "Deployed $name to https://$domain"
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
