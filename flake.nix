{
  description = "Idris2 hello world compiled to JavaScript and served from Cloudflare Workers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs.idris2Packages) buildIdris;

        cloudflare-workers = buildIdris {
          ipkgName = "cloudflare-workers";
          version = "0.1.0";
          src = ./cloudflare-workers;
          idrisLibraries = [ ];
        };
        datastar = buildIdris {
          ipkgName = "datastar";
          version = "0.1.0";
          src = ./datastar;
          idrisLibraries = [ ];
        };
        cloudflare-workers-datastar = buildIdris {
          ipkgName = "cloudflare-workers-datastar";
          version = "0.1.0";
          src = ./cloudflare-workers-datastar;
          idrisLibraries = [ cloudflare-workers datastar ];
        };
        site = buildIdris {
          ipkgName = "site";
          src = ./site;
          idrisLibraries = [ cloudflare-workers datastar cloudflare-workers-datastar ];
        };

        # Build/deploy CLI (tools/backstage/main.zig): one static binary, no runtime deps.
        backstage = pkgs.stdenv.mkDerivation {
          pname = "backstage";
          version = "0.1.0";
          src = ./tools/backstage;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
            zig test main.zig
            mkdir -p $out/bin
            # Baseline CPU: Zig defaults to the build machine's CPU, and this
            # binary runs elsewhere (cached for other CI runners).
            zig build-exe -O ReleaseSmall -mcpu=baseline -femit-bin=$out/bin/backstage main.zig
          '';
        };

        # Everything CI needs, with no Nix required to run it: an idris2 that
        # already finds our libraries, plus backstage. CI restores this
        # package's closure from the GitHub Actions cache straight into
        # /nix/store (see .github/actions/tools), skipping Nix entirely.
        ci-tools = pkgs.runCommand "backstage-ci-tools" { nativeBuildInputs = [ pkgs.makeBinaryWrapper ]; } ''
          mkdir -p $out/bin
          makeBinaryWrapper ${pkgs.idris2}/bin/idris2 $out/bin/idris2 \
            --prefix IDRIS2_PACKAGE_PATH : ${
              pkgs.lib.makeSearchPath "lib/idris2-${pkgs.idris2.version}" [
                cloudflare-workers.library'
                datastar.library'
                cloudflare-workers-datastar.library'
              ]
            }
          ln -s ${backstage}/bin/backstage $out/bin/backstage
        '';
      in
      {
        # Idris2 libraries, for other flakes to use as `idrisLibraries`.
        packages = {
          cloudflare-workers = cloudflare-workers.library';
          datastar = datastar.library';
          cloudflare-workers-datastar = cloudflare-workers-datastar.library';
          site = site.executable;
          inherit backstage ci-tools;
          default = site.executable;
        };

        # Entering a shell builds the libraries and puts them on
        # IDRIS2_PACKAGE_PATH, so `backstage build` can compile the site.
        devShells = {
          # Local development: adds library sources for editor tooling, and
          # wrangler (on Node.js) for `backstage dev`.
          default = pkgs.mkShell {
            inputsFrom = [ site.executable.withSource ];
            packages = [ pkgs.idris2 backstage pkgs.wrangler ];
            # Dev branches deploy from this machine on push (.githooks/pre-push).
            shellHook = ''
              git config core.hooksPath .githooks
            '';
          };
        };
      });
}
