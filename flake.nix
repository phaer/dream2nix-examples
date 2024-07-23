{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    dream2nix.url = "github:nix-community/dream2nix";
    systems.url = "github:nix-systems/default";
  };

  outputs = {
    self,
      nixpkgs,
      dream2nix,
      systems
  }: let
    lib = nixpkgs.lib;
    eachSystem = lib.genAttrs (import systems);

    limit = 500;
    mostPopular = lib.listToAttrs
      (lib.take limit
        (map
          (line: let
            parts = lib.splitString "==" line;
          in {
            name = lib.elemAt parts 0;
            value = lib.elemAt parts 1;
          })
          (lib.splitString "\n"
            (lib.removeSuffix "\n"
              (lib.readFile ./500-most-popular-pypi-packages.txt)))));

    toSkip = [
      "dataclasses"  # in pythons stdlib since python 3.8
      "pypular" # https://tomaselli.page/blog/pypular-removed-from-pypi.html
      # locking currently broken
      "great-expectations"  # versioneer is broken with python3.12
      "opencv-python" # distutils, scikit-build
      "opt-einsum"  # versioneer is broken with python3.12
      "pandas"  # numpy import broken
      "pydata-google-auth" # versioneer is broken with python3.12
      "scipy" # f2py fortran failed
    ];
    overrides = import ./overrides.nix { inherit lib; };
    requirements = lib.filterAttrs (n: v: !(builtins.elem n toSkip)) mostPopular;
    makePackage = {name, version, system}:
      dream2nix.lib.evalModules {
        packageSets.nixpkgs = nixpkgs.legacyPackages.${system};
        modules = [
          ({
            config,
              lib,
              dream2nix,
              ...
          }: {
            inherit name version;
            imports = [
              dream2nix.modules.dream2nix.pip
            ];
            paths.lockFile = "locks/${name}.${system}.json";
            paths.projectRoot = ./.;
            paths.package = ./.;

            buildPythonPackage.pyproject = lib.mkDefault true;
            mkDerivation.nativeBuildInputs = with config.deps.python.pkgs; [ setuptools wheel ];
            pip = {
              ignoredDependencies = [ "wheel" "setuptools" ];
              requirementsList = [ "${name}==${version}" ];
              pipFlags = ["--no-binary" name];
            };
          })
          (overrides.${name} or {})
        ];
      };
  in {
    packages = eachSystem (system: lib.mapAttrs (name: version: makePackage {inherit name version system; }) requirements);
    apps = eachSystem(system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lockAll = pkgs.writeShellApplication {
        name = "lock-all";
        runtimeInputs = [ pkgs.nix-eval-jobs pkgs.parallel pkgs.jq ];
        text = ''
          nix-eval-jobs --flake .#lib.${system}.lockScripts \
           | parallel --pipe "jq -r .drvPath" \
           | parallel "nix build --no-link --print-out-paths {}^out" \
           | parallel "{}/bin/refresh"
        '';
      };
    in {
      lock-all = {
        type = "app";
        program = lib.getExe lockAll;
      };
    });

    lib = eachSystem (system:
      let
        packages = self.packages.${system};
        partitioned = builtins.partition (package:
          let
            result = builtins.tryEval package.config.lock.isValid;
          in
            result.success && result.value
        ) (builtins.attrValues packages);
        packagesValid = map (p: p.config.name) partitioned.right;
        packagesToLock = map (p: p.config.name) partitioned.wrong;
        lockScripts = lib.genAttrs packagesToLock (name: packages.${name}.lock);

    in {
      inherit packages packagesValid packagesToLock lockScripts;
    });
    devShells = eachSystem(system: let
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3.withPackages (ps: [
        ps.jinja2
        ps.python-lsp-server
        ps.python-lsp-ruff
        ps.pylsp-mypy
        ps.ipython
      ]);

    in {
      default = pkgs.mkShell {
        packages = [ python pkgs.ruff pkgs.mypy pkgs.black ];
      };
    });

  };
}
