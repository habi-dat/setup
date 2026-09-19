{
  description = "habi*DAT setup -- development and test environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # bats plus the two helper libraries the suite loads via
        # `bats_load_library`. Exposing them through BATS_LIB_PATH keeps the
        # test helpers agnostic of whether bats came from Nix or from npm.
        batsWith = pkgs.bats.withLibraries (p: [ p.bats-support p.bats-assert ]);

        # lib/render.py needs only Jinja2, so any current Python works. This
        # replaced j2cli, which imports `imp` (removed in Python 3.12) and
        # `pkg_resources` (dropped from setuptools 81) and so had to be pinned to
        # an old interpreter and patched.
        python = pkgs.python3.withPackages (ps: [ ps.jinja2 ]);

        # Everything the test suite itself needs. Tiers 0-4 never talk to a
        # Docker daemon -- the docker CLI is only used for `compose config`.
        testTools = [
          batsWith
          pkgs.bash
          pkgs.shellcheck
          python
          pkgs.docker-client
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.gnutar
          pkgs.gzip
          pkgs.gettext # envsubst, used by lib/template.sh for non-.j2 templates
          pkgs.yq-go # validates .github/workflows/*.yml in the static tier
          pkgs.ncurses # tput, for the colour code paths in lib/common.sh
        ];

        # Additionally needed to actually run an install against real Docker.
        runtimeTools = [
          pkgs.openssl
          pkgs.git
          pkgs.jq
          pkgs.mkcert
          pkgs.nssTools
          pkgs.netcat-gnu
          pkgs.curl
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          name = "habidat-setup";
          packages = testTools ++ runtimeTools ++ [ pkgs.nodejs ];

          # bats_load_library resolves helper libraries from here.
          BATS_LIB_PATH = "${batsWith}/share/bats";

          shellHook = ''
            echo "habi*DAT setup dev shell"
            echo "  bats       $(bats --version | awk '{print $2}')"
            echo "  shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
            echo "  python     $(python3 --version | awk '{print $2}') (jinja2 $(python3 -c 'import jinja2; print(jinja2.__version__)'))"
            echo "  docker     $(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || echo 'not available')"
            echo ""
            echo "  ./tests/run.sh            run the whole suite"
            echo "  ./tests/run.sh 20_version run one file"
            echo ""
          '';
        };

        # `nix develop .#ci` -- test tooling only, no runtime extras, no node.
        devShells.ci = pkgs.mkShell {
          name = "habidat-setup-ci";
          packages = testTools;
          BATS_LIB_PATH = "${batsWith}/share/bats";
        };

        # `nix run .#tests` / `nix flake check`
        packages.tests = pkgs.writeShellApplication {
          name = "habidat-tests";
          runtimeInputs = testTools;
          text = ''
            export BATS_LIB_PATH="${batsWith}/share/bats"
            exec ./tests/run.sh "$@"
          '';
        };

        apps.tests = {
          type = "app";
          program = "${self.packages.${system}.tests}/bin/habidat-tests";
        };
      });
}
