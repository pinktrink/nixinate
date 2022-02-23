{
  description = "Nixinate your systems 🕶️";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
            mkDeployScript = { machine, dryRun }: let
              inherit (builtins) abort;

              n = flake.nixosConfigurations.${machine}._module.args.nixinate;
              user = n.sshUser or "root";
              host = n.host;
              where = n.buildOn or "remote";
              remote = if where == "remote" then true else if where == "local" then false else abort "_module.args.nixinate.buildOn is not set to a valid value of 'local' or 'remote'";
              switch = if dryRun then "dry-activate" else "switch";
              rollbackScript = let
                inherit (builtins) toString;
                inherit (final.lib.strings) optionalString;

                r = n.rollback or {};
                enabled = r.enabled or true;
                init = r.init or 500;
                limit = r.limit or 8;
                timeout = r.timeout or 10;
             in optionalString enabled ''
                rollbackAccumulator=${toString limit}
                exponent=0
                until ${final.openssh}/bin/ssh -o ConnectTimeout=${toString timeout} -t ${user}@${host} 'sudo rm /tmp/.nixinate-deploy-success'; do
                  rollbackWait=$((${toString init} * (2 ** exponent++)))
                  echo "Could not access ${machine}, trying again in $rollbackWait milliseconds." &>2
                  sleep $((rollbackWait / 1000))
                  if [[ $((--rollbackAccumulator)) == 0 ]];  # --rollbackAccumulator may appear as a flag, however it's inside of $(()), so it decrements the value and yields it.
                    echo "Cannot access ${machine}. Rollback will happen." &>2
                    exit 1
                  ]];
                done
              '';
              script = ''
                set -e
                echo "🚀 Deploying nixosConfigurations.${machine} from ${flake}"
                echo "👤 SSH User: ${user}"
                echo "🌐 SSH Host: ${host}"
              '' + (if remote then ''
                echo "🚀 Sending flake to ${machine} via rsync:"
                ( set -x; ${final.rsync}/bin/rsync -q -vz --recursive --zc=zstd ${flake}/* ${user}@${host}:/tmp/nixcfg/ )
                echo "🤞 Activating configuration on ${machine} via ssh:"
                ( set -x; ${final.openssh}/bin/ssh -t ${user}@${host} 'sudo nixos-rebuild ${switch} --flake /tmp/nixcfg#${machine}' )
              '' else ''
                echo "🔨 Building system closure locally, copying it to remote store and activating it:"
                ( set -x; NIX_SSHOPTS="-t" ${final.nixos-rebuild}/bin/nixos-rebuild ${switch} --flake ${flake}#${machine} --target-host ${user}@${host} --use-remote-sudo )
              '') + rollbackScript + ''
                echo "${machine} has finished deploying."
	      '';
            in final.writeScript "deploy-${machine}.sh" script;
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
                         dryRun = false;
                       });
                     }
                   )
                   // nixpkgs.lib.genAttrs
                      (map (a: a + "-dry-run") validMachines)
                      (x:
                        {
                          type = "app";
                          program = toString (mkDeployScript {
                            machine = x;
                            dryRun = true;
                          });
                        }
                      )
               );
          };
        };
      nixinate = forAllSystems (system: nixpkgsFor.${system}.generateApps);
      apps = nixinate.x86_64-linux examples;
    };
}
