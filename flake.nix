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
        # deps
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

      # nixosConfigurations = {
      #   # testContainer =  {}
      # };

      nixosModule = { pkgs, lib, config, ... }:
        with lib;
        let
          subspace = self.defaultPackage."${config.system}";
          cfg = config.services.subspace;
        in
        {
          options = {
            services.subspace = {
              enable = mkEnableOption "subspace";
              dataDir = mkOption {
                description = "Path to data folder";
                default = "/var/subspace/data";
                type = types.path;
              };
              privateKeyFile = {
                description = "Path to Wireguard private key";
                default = "/secrets/subspace.private";
                type = types.path;
              };
              params = mkOption {
                description = "Parameters for Subspace binary";
                default = "--http-host localhost -http-addr \":3331\" -http-insecure";
                type = types.str;
              };
            };

          };
          config = mkIf cfg.enable {
            systemd.services.subspace = {
              description = "AMule daemon";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              preStart = ''
                mkdir -p ${cfg.dataDir}
                pushd ${cfg.dataDir}

                mkdir -p wireguard/clients
                touch wireguard/clients/null.conf

                mkdir -p wireguard/peers
                touch wireguard/peers/null.conf

                cp ${cfg.privateKeyFile} wireguard/server.private
                cat ${cfg.privateKeyFile} | ${pkgs.wireguard-tools}/bin/wg pubkey > server.public

                chmod -R u+r a-rwx ${user} ${cfg.dataDir}
                chown -r ${user} ${cfg.dataDir}
              '';

              script = ''
                cd ${subspace}/libexec
                ${subspace}/bin/subspace \
                  -datadir=${cfg.dataDir} \
                  ${cfg.params}
              '';
            };
          };
        };

    };

}
