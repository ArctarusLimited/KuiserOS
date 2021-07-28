{ config, lib, pkgs, ... }: let
    inherit (lib.kuiser) mkProfile;
in mkProfile {
    requires.profiles = [
        "core/boot"
        "core/nix"
        "core/security"

        # global hardware profiles
        "hardware/common"
    ];

    networking.useDHCP = false;

    hardware.enableRedistributableFirmware = true;

    environment = {
        systemPackages = with pkgs; [
            # general purpose tools
            direnv tree jq screen skim rsync
            ripgrep zip unzip git pwgen openssl

            # network tools
            nmap whois curl wget

            # process tools
            htop psmisc

            # disk partition tools
            cryptsetup dosfstools gptfdisk
            parted fd file ntfs3g

            # hardware tools
            usbutils pciutils
            lshw hwinfo dmidecode

            # nix tools
            nix-index nixos-option

            # others
            binutils coreutils dnsutils
            iputils moreutils utillinux
        ];

        # set up general pager options
        variables = {
            PAGER = "less -R";
            LESS = "-iFJMRW -x4";
            LESSOPEN = "|${pkgs.lesspipe}/bin/lesspipe.sh %s";

            # Vault Production Hardening:
            # hide vault commands by default
            HISTIGNORE = "&:vault*";
        };

        shellAliases = {
            # fix nixos-option
            nixos-option = "nixos-option -I nixpkgs=${toString ../../compat}";
        };
    };

    programs = {
        # setcap wrappers for security hardening
        mtr.enable = true;
        traceroute.enable = true;

        # neovim as text editor
        neovim = {
            enable = true;
            viAlias = true;
            vimAlias = true;
        };
    };

    services = {
        # prefer free alternatives
        mysql.package = lib.mkOptionDefault pkgs.mariadb;

        # enable recommended settings by default for nginx
        nginx = {
            enableReload = lib.mkDefault true;

            recommendedGzipSettings = lib.mkDefault true;
            recommendedOptimisation = lib.mkDefault true;
            recommendedProxySettings = lib.mkDefault true;
            recommendedTlsSettings = lib.mkDefault true;
        };
    };
}
