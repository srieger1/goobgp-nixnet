# The OBGP fork of GoBGP (github.com/Stinktopf/gobgp, branch obgp-fixes).
#
# The daemon is plain GoBGP unless GOBGP_OPERA_ENABLED is "1" or "true", so one
# build provides both variants the experiment compares.
{
  pkgs,
  lib,
  src,
}:
let
  rev = src.rev or "unknown";
  shortRev = src.shortRev or (builtins.substring 0 7 rev);
in
pkgs.buildGoModule {
  pname = "gobgp";
  version = "4.2.0+obgp.${shortRev}";

  inherit src;

  # Both the daemon and the CLI the scripts drive it with.
  subPackages = [
    "cmd/gobgpd"
    "cmd/gobgp"
  ];

  vendorHash = "sha256-y8nhrKQnTXfnDDyr/xZd5b9ccXaM85rd8RKHtoDBuwI=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/osrg/gobgp/v4/internal/pkg/version.COMMIT=${shortRev}"
  ];

  meta = {
    description = "OBGP: an oscillation-free BGP router based on GoBGP";
    homepage = "https://github.com/Stinktopf/gobgp";
    license = lib.licenses.asl20;
    mainProgram = "gobgpd";
    platforms = lib.platforms.linux;
  };
}
