{
  outputs = { self, nixpkgs }:
    let onPkgs = fn: builtins.mapAttrs fn nixpkgs.legacyPackages;
    in
    {
      defaultPackage = onPkgs (_: pkgs:
        let
          deps = pkgs.runCommand "subspace-deps"
            {
              buildInputs = with pkgs; [ go cacert ];
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = "";
            } ''
            mkdir -p $out
            export HOME=/build
            export GOPATH=$out
            cd ${./.}
            go install ./cmd/subspace
          '';
          goPackagePath = "github.com/subspacecommunity/subspace";
          version = "1.5.0";
        in
        pkgs.buildGoPackage {
          inherit goPackagePath version;
          src = ./.;
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

            systemd.services.subspace = {
              description = "A simple WireGuard VPN server GUI";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = "${cfg.package}/libexec";
              };

              preStart = ''
                pushd ${cfg.dataDir}

                mkdir -p wireguard/clients
                touch wireguard/clients/null.conf

                mkdir -p wireguard/peers
                touch wireguard/peers/null.conf

                cp ${cfg.privateKeyFile} wireguard/server.private
                cat ${cfg.privateKeyFile} | ${pkgs.wireguard-tools}/bin/wg pubkey > server.public
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
