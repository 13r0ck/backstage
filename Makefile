.PHONY: build dev clean

build:
	idris2 --cg javascript --build hello.ipkg

dev: build
	wrangler dev

# Deploys go through scripts/deploy.sh, which picks the Worker name and domain.

clean:
	rm -rf build
