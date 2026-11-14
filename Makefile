.PHONY: build dev clean

# Run inside `nix develop`, which provides the Idris2 libraries this depends on.
build:
	cd site && idris2 --build site.ipkg

dev: build
	wrangler dev

# Deploys go through scripts/deploy.sh, which picks the Worker name and domain.

clean:
	rm -rf */build
