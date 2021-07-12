{ lib, pkgs, ... }:
{
    # Extra security hardening options for servers
    nix = {
        useSandbox = true;
        allowedUsers = [ "@wheel" ];
        trustedUsers = [ "root" "@wheel" ];
    };

    boot = {
        # don't need ntfs for production
        blacklistedKernelModules = [ "ntfs" ];

        kernel.sysctl = {
            # Disable kernel tracing
            "kernel.ftrace_enabled" = false;
        };
    };
}