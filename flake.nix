{
  outputs = { self, nixpkgs }:
    let onPkgs = fn: builtins.mapAttrs fn nixpkgs.legacyPackages;
    in
    {
      packages = onPkgs (_: pkgs:
        {
          patchedWGTools = pkgs.wireguard-tools.overrideDerivation (super: {
            patches = super.patches ++ [
              ./wg-quick-no-uid.patch
            ];
          });
        }
      );
      defaultPackage = onPkgs (_: pkgs:
        let
          goPackagePath = "github.com/subspacecommunity/subspace";
          version = "1.5.0";
        in
        pkgs.buildGoPackage {
          inherit goPackagePath version;
          src = nixpkgs.lib.cleanSource ./.;
          name = "subspace";
          goDeps = ./deps.nix;
          nativeBuildInputs = with pkgs; [ go-bindata which diffutils ];
          buildPhase = ''
            runHook preBuild
            cd go/src/${goPackagePath}
            export CGO_ENABLED=0
            rm -rf subspace
            go-bindata -o cmd/subspace/bindata.go --prefix "web/" --pkg main web/...
            go build -v --compiler gc --ldflags "-extldflags -static -s -w -X main.version=${version}" -o subspace ./cmd/subspace
            runHook postBuild
          '';
          installPhase = ''
            install -Dm777 subspace $out/bin/subspace

            mkdir -p $out/libexec
            cp -r web $out/libexec/web
          '';
        }
      );
      devShell = onPkgs (system: pkgs: with pkgs; mkShell {
        buildInputs = [ self.packages.${system}.patchedWGTools wg-bond go go-bindata ];
      });

      nixosModule = { pkgs, lib, config, ... }:
        with lib;
        let
          cfg = config.services.subspace;
        in
        {
          options.services.subspace = {
            enable = mkEnableOption "subspace";

            package = mkOption {
              description = "A package from which to take subspace";
              default = self.defaultPackage.${pkgs.system};
              type = types.package;
            };

            privateKeyFile = mkOption {
              description = "Path to Wireguard private key";
              default = "/secrets/subspace.private";
              type = types.str;
            };

            user = mkOption {
              description = "User account under which Subspace runs.";
              default = "subspace";
              type = types.str;
            };
            group = mkOption {
              description = "Group account under which Subspace runs.";
              default = "subspace";
              type = types.str;
            };

            httpHost = mkOption {
              description = "The host to listen on and set cookies for";
              default = "localhost";
              type = types.str;
            };
            backlink = mkOption {
              description = "The page to set the home button to";
              default = "/";
              type = types.str;
            };
            dataDir = mkOption {
              description = "Path to data folder";
              default = "/var/lib/subspace";
              type = types.str;
            };
            debug = mkOption {
              description = "Place subspace into debug mode for verbose log output";
              default = false;
              type = types.bool;
            };
            httpInsecure = mkOption {
              description = "enable session cookies for http and remove redirect to https";
              default = false;
              type = types.bool;
            };
            letsencrypt = mkOption {
              description = "Whether or not to use a LetsEncrypt certificate";
              default = true;
              type = types.bool;
            };
            httpAddr = mkOption {
              description = "HTTP Listen address";
              default = ":3331";
              type = types.str;
            };
            params = mkOption {
              description = "Parameters for Subspace binary";
              default = "";
              type = types.str;
            };
            proxyPort = mkOption {
              description = "Port for managed WireGuard interface";
              default = "53222";
              type = types.str;
            };
          };

          config = mkIf cfg.enable {
            users.users = optionalAttrs (cfg.user == "subspace") ({
              subspace = {
                isSystemUser = true;
                group = cfg.group;
                # uid = config.ids.uids.subspace;
                description = "Subspace WireGuard GUI user";
                home = cfg.dataDir;
              };
            });

            users.groups = optionalAttrs (cfg.group == "subspace") ({
              subspace = {
                # gid = config.ids.gids.subspace;
              };
            });

            systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group}" ];

            systemd.services.subspace = rec {
              description = "A simple WireGuard VPN server GUI";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                User = cfg.user;
                Group = cfg.group;

                CapabilityBoundingSet = "CAP_NET_ADMIN";
                AmbientCapabilities = "CAP_NET_ADMIN";

                ReadWritePaths = [ "${cfg.dataDir}" ];
                RestrictAddressFamilies = [
                  "AF_INET"
                  "AF_INET6"
                  "AF_NETLINK"
                ];

                RestrictNamespaces = "yes";
                DeviceAllow = "no";
                KeyringMode = "private";
                NoNewPrivileges = "yes";
                NotifyAccess = "none";
                PrivateDevices = "yes";
                PrivateMounts = "yes";
                PrivateTmp = "yes";
                ProtectClock = "yes";
                ProtectControlGroups = "yes";
                ProtectHome = "yes";
                ProtectKernelLogs = "yes";
                ProtectKernelModules = "yes";
                ProtectKernelTunables = "yes";
                ProtectProc = "invisible";
                ProtectSystem = "strict";
                RestrictSUIDSGID = "yes";
                SystemCallArchitectures = "native";
                SystemCallFilter = [
                  "~@clock"
                  "~@debug"
                  "~@module"
                  "~@mount"
                  "~@raw-io"
                  "~@reboot"
                  "~@swap"
                  # "~@privileged"
                  "~@resources"
                  "~@cpu-emulation"
                  "~@obsolete"
                ];
                RestrictRealtime = "yes";
                Delegate = "no";
                LockPersonality = "yes";
                MemoryDenyWriteExecute = "yes";
                RemoveIPC = "yes";
                UMask = "0027";
                ProtectHostname = "yes";
                ProcSubset = "pid";

                WorkingDirectory = "${cfg.package}/libexec";
              };

              path = with pkgs; [ wg-bond self.packages.${system}.patchedWGTools iptables bash gawk ];

              preStart = ''
                wg-bond -c ${cfg.dataDir}/wireguard/wg-bond.json conf subspace-root > ${cfg.dataDir}/subspace.conf
                wg-quick up ${cfg.dataDir}/subspace.conf

                chmod -R u+rwX,g+rX,o-rwx ${cfg.dataDir}
                chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}
              '';

              postStop = ''
                wg-quick down ${cfg.dataDir}/wireguard/subspace.conf
              '';

              script = ''
                ${cfg.package}/bin/subspace \
                  --http-host="${cfg.httpHost}" \
                  --backlink="${cfg.backlink}" \
                  --datadir="${cfg.dataDir}" \
                  --debug="${if cfg.debug then "true" else "false"}" \
                  --http-addr="${cfg.httpAddr}" \
                  --http-insecure="${if cfg.httpInsecure then "true" else "false"}" \
                  --letsencrypt="${if cfg.letsencrypt then "true" else "false"}" \
                  ${cfg.params}
              '';
            };
          };
        }
      ;
    };

}
