{ lib, pkgs, hardware, ... }:
let
  inherit (lib.kuiser) mkProfile;
in
mkProfile {
  imports = [
    hardware.common-pc-laptop
    hardware.common-pc-laptop-ssd
    hardware.common-cpu-intel-kaby-lake
  ];

  requires.profiles = [
    "hardware/capabilities/fingerprint"
  ];

  # thunderbolt support
  services.hardware.bolt.enable = true;

  # hardware video offload
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
}
