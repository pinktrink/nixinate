{
  description = "Nixinate your systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = { self, nixpkgs, ... }@inputs:
    let
      version = builtins.substring 0 8 self.lastModifiedDate;
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      forSystems = systems: f:
        nixpkgs.lib.genAttrs systems
        (system: f system nixpkgs.legacyPackages.${system});
      forAllSystems = forSystems supportedSystems;
      nixpkgsFor = forAllSystems (system: pkgs: import nixpkgs { inherit system; overlays = [ self.overlay ]; });
    in rec
    {
      herculesCI.ciSystems = [ "x86_64-linux" ];
      overlay = final: prev: {
        nixinate = {
          nix = prev.pkgs.writeShellScriptBin "nix"
            ''${final.nixVersions.unstable}/bin/nix --experimental-features "nix-command flakes" "$@"'';
          nixos-rebuild = prev.nixos-rebuild.override { inherit (final) nix; };
        };
        generateApps = flake:
          let
            machines = builtins.attrNames flake.nixosConfigurations;
            validMachines = final.lib.remove "" (final.lib.forEach machines (x: final.lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}" ));
            mkDeployScript = { machine }: let
              inherit (builtins) abort;
              inherit (final.lib) getExe optionalString concatStringsSep;
              nix = "${getExe final.nix}";
              nixos-rebuild = "${getExe final.nixos-rebuild}";
              openssh = "${getExe final.openssh}";
              flock = "${final.flock}/bin/flock";

              n = flake.nixosConfigurations.${machine}._module.args.nixinate;
              hermetic = n.hermetic or true;
              user = n.sshUser or "root";
              host = n.host;
              where = n.buildOn or "remote";
              remote = if where == "remote" then true else if where == "local" then false else abort "_module.args.nixinate.buildOn is not set to a valid value of 'local' or 'remote'";
              substituteOnTarget = n.substituteOnTarget or false;
              nixOptions = concatStringsSep " " (n.nixOptions or []);

              script =
              ''
                set -e
                sw=''${1:-test}
                echo "Deploying nixosConfigurations.${machine} from ${flake}"
                echo "SSH User: ${user}"
                echo "SSH Host: ${host}"
                echo "Rebuild Command: $sw"
              '' + (if remote then ''
                echo "Sending flake to ${machine} via nix copy:"
                ( set -x; ${nix} ${nixOptions} copy ${flake} --to ssh://${user}@${host} )
              '' + (if hermetic then ''
                echo "Activating configuration hermetically on ${machine} via ssh:"
                ( set -x; ${nix} ${nixOptions} copy --derivation ${nixos-rebuild} ${flock} --to ssh://${user}@${host} )
                ( set -x; ${openssh} -t ${user}@${host} "sudo nix-store --realise ${nixos-rebuild} ${flock} && sudo ${flock} -w 60 /dev/shm/nixinate-${machine} ${nixos-rebuild} ${nixOptions} $sw --flake ${flake}#${machine}" )
              '' else ''
                echo "Activating configuration non-hermetically on ${machine} via ssh:"
                ( set -x; ${openssh} -t ${user}@${host} "sudo flock -w 60 /dev/shm/nixinate-${machine} nixos-rebuild $sw --flake ${flake}#${machine}" )
              '')
              else ''
                echo "Building system closure locally, copying it to remote store and activating it:"
                ( set -x; NIX_SSHOPTS="-t" ${flock} -w 60 /dev/shm/nixinate-${machine} ${nixos-rebuild} ${nixOptions} $sw --flake ${flake}#${machine} --target-host ${user}@${host} --use-remote-sudo ${optionalString substituteOnTarget "-s"} )

              '');
            in final.writeShellScript "deploy-${machine}.sh" script;
          in
          {
             nixinate =
               (
                 nixpkgs.lib.genAttrs
                   validMachines
                   (x:
                     {
                       type = "app";
                       program = toString (mkDeployScript {
                         machine = x;
                       });
                     }
                   )
               );
          };
        };
      nixinate = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateApps);
      checks = forAllSystems (system: pkgs:
        let
          vmTests = import ./tests {
            makeTest = (import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).makeTest;
            inherit inputs; pkgs = nixpkgsFor.${system};
          };
        in
        pkgs.lib.optionalAttrs pkgs.stdenv.isLinux vmTests # vmTests can only be ran on Linux, so append them only if on Linux.
        //
        {
          # Other checks here...
        }
      );
    };
}
