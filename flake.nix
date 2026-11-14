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
      in
      {
        # Idris2 libraries, for other flakes to use as `idrisLibraries`.
        packages = {
          cloudflare-workers = cloudflare-workers.library';
          datastar = datastar.library';
          cloudflare-workers-datastar = cloudflare-workers-datastar.library';
          site = site.executable;
          default = site.executable;
        };

        # Entering the shell builds the libraries (with source, for editor
        # tooling) and puts them on IDRIS2_PACKAGE_PATH for `make build`.
        devShells.default = pkgs.mkShell {
          inputsFrom = [ site.executable.withSource ];
          packages = [
            pkgs.idris2
            pkgs.nodejs
            pkgs.wrangler
          ];
        };
      });
}
