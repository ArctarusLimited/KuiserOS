{ config, lib, pkgs, regions, ... }:

with lib;

let
    cfg = config.services.eidolon;
in {
    imports = [ ./firewall ./router ./tunnel ];

    options = {
        services.eidolon = {
            enable = mkEnableOption "Eidolon RIS";

            underlay = mkOption {
                type = with types; nullOr str;
                default = null;
            };

            network = mkOption {
                type = with types; nullOr str;
                default = null;
            };

            region = mkOption {
                type = with types; nullOr str;
                default = null;
            };
        };
    };

    config = {
        _module.args.utils = (import ./utils.nix {
            inherit config lib regions;
        });
    };
}