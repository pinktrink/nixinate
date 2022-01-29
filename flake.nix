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
            mkDeployScript = machine: let
              rollback = flake.nixosConfigurations.${machine}._module.args.nixinate.rollback or {};
              rollbackEnabled = rollback.enable or true;
              rollbackInit = rollback.init or 500;
              rollbackLimit = rollback.limit or 8;
              rollbackTimeout = rollback.timeout or 10;
              rollbackScript = if rollbackEnabled then ''
                racc=${toString rollbackLimit}
                exp=0
                until ${final.openssh}/bin/ssh -o ConnectTimeout=${toString rollbackTimeout} -t $SSH_USER@$SSH_HOST 'sudo rm /tmp/.nixinate-deploy-succeeded' &> /dev/null; do
                  rbp=$((${toString rollbackInit} * (2 ** $exp)))
                  echo "Could not access ${machine}, trying again in $rbp milliseconds."
                  sleep $(($rbp / 1000)
                  exp=$(($exp + 1))
                  racc=$(($racc - 1))
                  if [[ $racc == 0 ]]; then
                    echo "Cannot access ${machine}. Rollback will happen." >&2
                    exit 1
                  fi
                done
		echo "${machine} has finished deploying."
              '' else "";
	    in final.writeScript "deploy-${machine}.sh" ''
              set -e
              SSH_USER=${flake.nixosConfigurations.${machine}._module.args.nixinate.sshUser}
              SSH_HOST=${flake.nixosConfigurations.${machine}._module.args.nixinate.host}
              BUILD_ON=${flake.nixosConfigurations.${machine}._module.args.nixinate.buildOn}
              SYSTEM_CLOSURE=${flake}#nixosConfigurations.${machine}.config.system.build.toplevel

              echo "🚀 Deploying nixosConfigurations.${machine} from ${flake}"
              echo "👤 SSH User: $SSH_USER"
              echo "🌐 SSH Host: $SSH_HOST"
              if [ $BUILD_ON = "remote" ]; then
                echo "🚀 Sending flake to ${machine} via rsync:"
                ( set -x; ${final.rsync}/bin/rsync -q -vz --recursive --zc=zstd ${flake}/* $SSH_USER@$SSH_HOST:/tmp/nixcfg/ )
                echo "🤞 Activating configuration on ${machine} via ssh:"
                ( set -x; ${final.openssh}/bin/ssh -t $SSH_USER@$SSH_HOST 'sudo nixos-rebuild switch --flake /tmp/nixcfg#${machine}' )
                ${rollbackScript}
              elif [ $BUILD_ON = "local" ]; then
                echo "🔨 Building system closure locally and copying it to remote store:"
                ( set -x; ${final.nixFlakes}/bin/nix copy --to ssh://$SSH_USER@$SSH_HOST $SYSTEM_CLOSURE )
                echo "🤞 Activating configuration on ${machine} via ssh:"
                SYSTEM_CLOSURE_PATH=$(${final.nixFlakes}/bin/nix path-info $SYSTEM_CLOSURE)
                ( set -x; ${final.openssh}/bin/ssh -t $SSH_USER@$SSH_HOST "sudo $SYSTEM_CLOSURE_PATH/bin/switch-to-configuration switch" )
                ${rollbackScript}
              else
                echo "_module.args.nixinate.buildOn is not set to a valid value of 'local' or 'remote'"
              fi
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
                       program = toString (mkDeployScript x);
                     }
                   )
               );
          };
        };
      nixinate = forAllSystems (system: nixpkgsFor.${system}.generateApps);
      apps = nixinate.x86_64-linux examples;
    };
}
