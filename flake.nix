{
  description = "Nixinate your systems 🕶️";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-21.11";
    examples.url = "path:./examples";
  };
  outputs = { self, nixpkgs, examples, ... }:
    let
      version = builtins.substring 0 8 self.lastModifiedDate;
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; overlays = [ self.overlay ]; });
    in rec
    {
      overlay = final: prev: {
        generateApps = flake:
          let
            machines = builtins.attrNames flake.nixosConfigurations;
            validMachines = final.lib.remove "" (final.lib.forEach machines (x: final.lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}" ));
            mkDeployScript = dry: machine: let
              inherit (builtins) abort;

              n = flake.nixosConfigurations.${machine}._module.args.nixinate;
              user = n.sshUser or "root";
              host = n.host;
              closure = "${flake}#nixosConfigurations.${machine}.config.system.build.toplevel";
              where = n.buildOn or "remote";
              remote = if where == "remote" then true else if where == "local" then false else abort "_module.args.nixinate.buildOn is not set to a valid value of 'local' or 'remote'";
              switch = if dry then "dry-activate" else "switch";
              script = (if remote then ''
                echo "🚀 Sending flake to ${machine} via rsync:"
                ( set -x; ${final.rsync}/bin/rsync -q -vz --recursive --zc=zstd ${flake}/* ${user}@${host}:/tmp/nixcfg/ )
                echo "🤞 Activating configuration on ${machine} via ssh:"
                ( set -x; ${final.openssh}/bin/ssh -t ${user}@${host} 'sudo nixos-rebuild ${switch} --flake /tmp/nixcfg#${machine}' )
              '' else ''
                echo "🔨 Building system closure locally and copying it to remote store:"
                ( set -x; ${final.nixFlakes}/bin/nix copy --to ssh://${user}@${host} ${closure} )
                echo "🤞 Activating configuration on ${machine} via ssh:"
                SYSTEM_CLOSURE_PATH=$(${final.nixFlakes}/bin/nix path-info ${closure})
                ( set -x; ${final.openssh}/bin/ssh -t ${user}@${host} "sudo $SYSTEM_CLOSURE_PATH/bin/switch-to-configuration ${switch}" )
              '') + ''
                echo "🚀 Deploying nixosConfigurations.${machine} from ${flake}"
                echo "👤 SSH User: ${user}"
                echo "🌐 SSH Host: ${host}"
              '';
            in final.writeScript "deploy-${machine}.sh" ''
              set -e
              SYSTEM_CLOSURE=${flake}#nixosConfigurations.${machine}.config.system.build.toplevel
              ${script}
            '';
          in
          {
             nixinate =
               (
                 nixpkgs.lib.genAttrs
                   validMachines
                   (x:
                     {
                       type = "app";
                       program = toString (mkDeployScript false x);
                     }
                   )
                   // nixpkgs.lib.genAttrs
                      (map (a: a ++ "-dry-run") validMachines)
                      (x:
                        {
                          type = "app";
                          program = toString (mkDeployScript true x);
                        }
                      )
               );
          };
        };
      nixinate = forAllSystems (system: nixpkgsFor.${system}.generateApps);
      apps = nixinate.x86_64-linux examples;
    };
}
