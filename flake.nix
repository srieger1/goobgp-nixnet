{
  description = "NixNet environment for gobgp / OBGP: the BAD GADGET topology, plain BGP vs OBGP";

  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "git+https://github.com/hercules-ci/flake-parts";
    nixnet.url = "git+https://github.com/birneee/nixnet";
    gobgp-src = {
      url = "git+https://github.com/Stinktopf/gobgp?ref=master";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, lib, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          gobgp = import ./gobgp.nix {
            inherit pkgs lib;
            src = inputs.gobgp-src;
          };
          topology = import ./topology.nix;
          mkEnv =
            obgp:
            import ./nixnet.nix {
              inherit
                pkgs
                lib
                gobgp
                topology
                obgp
                ;
            };
          obgpEnv = mkEnv true;
          bgpEnv = mkEnv false;

          # Same diagram as nixnet's mkMermaidSvg, but rendered with HTML labels
          # off. nixnet's default puts every label in a <foreignObject>, which
          # GitHub's markdown sanitizer strips, leaving an unlabelled diagram in
          # the README; plain <text> elements survive. Both the top-level and
          # the flowchart `htmlLabels` switch are needed — with only one of them
          # set, mermaid still renders the node labels as HTML.
          mermaidConfig = pkgs.writeText "mermaid-config.json" (
            builtins.toJSON {
              maxTextSize = 100000;
              maxEdges = 1000;
              htmlLabels = false;
              flowchart.htmlLabels = false;
            }
          );
          mermaidSvg = pkgs.runCommand "topology.svg" {
            buildInputs = [ pkgs.mermaid-cli ];
            FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.liberation_ttf ]; };
            HOME = "/tmp";
          } ''
            mmdc -c ${mermaidConfig} -i ${nixnet.mkMermaid obgpEnv.config} -o $out
          '';
        in
        {
          packages = {
            inherit gobgp;

            # nix run .          -> OBGP (GOBGP_OPERA_ENABLED=true)
            # nix run .#bgp      -> plain GoBGP, same topology and scenario
            default = nixnet.mkExperiment obgpEnv.config;
            obgp = nixnet.mkExperiment obgpEnv.config;
            bgp = nixnet.mkExperiment bgpEnv.config;

            mermaid = nixnet.mkMermaid obgpEnv.config;
            mermaid-svg = mermaidSvg;
          };
        };
    };
}
