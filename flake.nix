{
  description = "A fork of the simple WireGuard VPN server GUI community maintained ";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }: (flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; overlays = [ self.overlay ]; };
    in
    {
      packages.subspace = pkgs.subspace;
      packages.wireguard-tools = pkgs.wireguard-tools;

      defaultPackage = self.packages.${system}.subspace;

      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [ self.packages.${system}.wireguard-tools wg-bond go go-bindata ];
      };
    })) // {
    overlay = final: prev: {
      wireguard-tools = prev.wireguard-tools.overrideDerivation (super: {
        patches = super.patches ++ [
          ./wg-quick-no-uid.patch
        ];
      });

      subspace =
        let
          goPackagePath = "github.com/subspacecommunity/subspace";
          version = "1.5.0";
        in
        final.buildGoPackage {
          inherit goPackagePath version;
          src = nixpkgs.lib.cleanSource ./.;
          name = "subspace";
          goDeps = ./deps.nix;
          nativeBuildInputs = with final; [ go-bindata which diffutils ];
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
        };
    };
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
          subnet = mkOption {
            description = "Subnet to be used by Subspace VPN";
            default = "10.0.0.0/24";
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

            path = with pkgs; [ wg-bond self.packages.${system}.wireguard-tools iptables bash gawk ];

            preStart = ''
              if [[ ! -f ${cfg.dataDir}/wireguard/wg-bond.json ]]; then
                mkdir -p ${cfg.dataDir}/wireguard/
                mkdir -p ${cfg.dataDir}/wireguard/clients
                mkdir -p ${cfg.dataDir}/wireguard/peers
                wg-bond -c ${cfg.dataDir}/wireguard/wg-bond.json init subspace --network "${cfg.subnet}"
                wg-bond -c ${cfg.dataDir}/wireguard/wg-bond.json add subspace-root --endpoint ${cfg.httpHost}:${cfg.proxyPort} --center --gateway --masquerade eth0
              fi
              if [[ ! -d ${cfg.dataDir}/wireguard/clients ]]; then mkdir -p ${cfg.dataDir}/wireguard/clients; fi
              if [[ ! -d ${cfg.dataDir}/wireguard/peers ]]; then mkdir -p ${cfg.dataDir}/wireguard/peers; fi
              wg-bond -c ${cfg.dataDir}/wireguard/wg-bond.json conf subspace-root > ${cfg.dataDir}/wireguard/subspace.conf
              wg-quick up ${cfg.dataDir}/wireguard/subspace.conf

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
      };
  };

}
