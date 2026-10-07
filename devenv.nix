# =============================================================================
# ADI ADSP (SC5xx / SC8xx, Cortex-A55) development environment
# =============================================================================
#
# What this provides:
#   * Three FHS sandboxes (see "FHS sandboxes" below) for building projects
#     whose build systems expect a conventional /usr, /lib layout:
#       - buildroot-fhs : Buildroot (host toolchain, hardening disabled)
#       - uboot-fhs     : U-Boot for ARM64, plus the ADI `ldr` boot-stream tool
#       - linux-fhs     : Linux kernel for ARM64
#   * Editor/dev tooling (ccls, clang-tools, cmake), board tooling (dtc,
#     mkimage, sshuttle), and neomutt with an OAuth2 helper (mutt_oauth2).
#   * Secrets (via secretspec, see secretspec.toml) exported as env vars.
#
# Usage:
#   $ direnv allow        # or: devenv shell
#   $ uboot-fhs           # drops you into a bash shell inside the sandbox
#   $ make ...            # build as usual; `exit` to leave the sandbox
#
# Requirements: Nix, devenv, (optionally) direnv. Secrets must be provisioned
# before entering the shell, run `secretspec check` to see what is missing.
#
# GnuPG is NOT provided here: gpg, gpg-agent and a pinentry program must come
# from the host system (e.g. NixOS `programs.gnupg.agent`), and GPG_TTY should
# be exported by your login shell. `mutt_oauth2` checks for this and fails
# with an error if it is missing.
# =============================================================================
{ pkgs, lib, config, inputs, secretspec, ... }:
let
  # ---------------------------------------------------------------------------
  # Cross toolchain
  # ---------------------------------------------------------------------------
  # nixpkgs' aarch64 cross set. `buildPackages.gcc` / `.binutils` are the
  # x86_64-hosted tools that target aarch64 and are exposed as
  # `aarch64-unknown-linux-gnu-*` (matches CROSS_COMPILE below).
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
  crossPrefix = "aarch64-unknown-linux-gnu-";

  # ---------------------------------------------------------------------------
  # adsp-ldr: ADI tool that turns U-Boot SPL/ELF images into boot streams
  # (.ldr) for ADSP processors. Not in nixpkgs; packaged in nix/adsp-ldr.nix
  # and installed as `${crossPrefix}ldr` so U-Boot's `$(CROSS_COMPILE)ldr`
  # finds it.
  # ---------------------------------------------------------------------------
  adsp-ldr = import ./nix/adsp-ldr.nix {
    inherit pkgs lib;
  };

  # ---------------------------------------------------------------------------
  # FHS sandboxes
  # ---------------------------------------------------------------------------
  # buildFHSEnv creates a bubblewrap sandbox with a classic filesystem layout,
  # which Buildroot / U-Boot / kernel build scripts generally assume.

  # Base userland every sandbox needs (roughly Buildroot's "mandatory
  # packages" list).
  commonFhsPkgs = pkgs: with pkgs; [
    gnumake bash patch gzip bzip2 findutils wget which
    gawk gnused file perl unzip rsync gcc bc ncurses
    ncurses.dev
  ];

  # Extra tools shared by the U-Boot and kernel builds: aarch64 cross
  # toolchain, Kconfig deps (bison/flex), host libs for signing/FIT/DT tools.
  crossBuildPkgs = pkgs: with pkgs; [
    crossPkgs.buildPackages.gcc
    crossPkgs.buildPackages.binutils
    bison flex python3 python3Packages.setuptools swig
    openssl openssl.dev dtc libuuid gnutls pkg-config
  ];

  # Buildroot builds its own cross toolchain, so it only needs host tools.
  # Nix's compiler-wrapper hardening flags break some Buildroot host
  # packages, so disable them inside the sandbox.
  buildroot_fhs = pkgs.buildFHSEnv {
    name = "buildroot-fhs";
    hardeningDisable = [ "all" ];
    targetPkgs = pkgs: (with pkgs; [
      binutils libusb1 libusb1.dev ninja libxcrypt
    ]) ++ commonFhsPkgs pkgs;
    runScript = "bash";
    profile = ''
      unset NIX_HARDENING_ENABLE
    '';
  };

  # U-Boot for ARM64. Includes adsp-ldr for generating .ldr boot streams.
  uboot_fhs = pkgs.buildFHSEnv {
    name = "uboot-fhs";
    targetPkgs = pkgs: [ adsp-ldr ] ++ crossBuildPkgs pkgs ++ commonFhsPkgs pkgs;
    runScript = "bash";
    profile = ''
      export CROSS_COMPILE=${crossPrefix}
    '';
  };

  # Linux kernel for ARM64.
  linux_fhs = pkgs.buildFHSEnv {
    name = "linux-fhs";
    targetPkgs = pkgs: crossBuildPkgs pkgs ++ commonFhsPkgs pkgs;
    runScript = "bash";
    profile = ''
      export ARCH=arm64
      export CROSS_COMPILE=${crossPrefix}
    '';
  };
in
{
  # ---------------------------------------------------------------------------
  # Packages available directly in the devenv shell
  # ---------------------------------------------------------------------------
  packages = [
    # FHS sandbox launchers (run by name: buildroot-fhs, uboot-fhs, linux-fhs)
    buildroot_fhs
    uboot_fhs
    linux_fhs

    # C/C++ development
    pkgs.ccls              # C/C++ language server
    pkgs.cmake
    pkgs.clang-tools       # clang-format, clang-tidy, etc. (does not provide cc)

    # Board / boot tooling
    pkgs.ubootTools        # mkimage, dumpimage, fw_printenv...
    pkgs.dtc               # device-tree compiler
    pkgs.inetutils         # telnet (OpenOCD), ftp, etc.
    pkgs.sshuttle          # VPN-over-SSH into the lab network

    # General utilities
    pkgs.jq
    pkgs.bat
    pkgs.pi-coding-agent

    # Mail: neomutt with GPG-encrypted OAuth2 tokens (Microsoft 365)
    pkgs.neomutt
    # Wrapper for neomutt's bundled OAuth2 helper so it can be used as
    # `mutt_oauth2` from neomuttrc without a separate copy of the script.
    # The token file is GPG-encrypted, so first verify the *host's* GnuPG
    # setup (gpg on PATH + a usable pinentry for gpg-agent) and fail loudly
    # instead of hanging or erroring obscurely inside the Python script.
    (pkgs.writeShellScriptBin "mutt_oauth2" ''
      die() { echo "mutt_oauth2: error: $*" >&2; exit 1; }

      command -v gpg >/dev/null && command -v gpgconf >/dev/null \
        || die "gpg/gpgconf not found on PATH; install GnuPG on the host (e.g. programs.gnupg.agent.enable)"

      # gpgconf does not report pinentry-program, so read the agent configs
      # directly. The per-user file overrides the system-wide one.
      conf_pinentry() {
        [ -r "$1" ] && sed -n 's/^[[:space:]]*pinentry-program[[:space:]]\{1,\}//p' "$1" | tail -n1
      }
      pinentry="$(conf_pinentry "$(gpgconf --list-dirs homedir)/gpg-agent.conf")"
      [ -n "$pinentry" ] || pinentry="$(conf_pinentry "$(gpgconf --list-dirs sysconfdir)/gpg-agent.conf")"
      [ -n "$pinentry" ] || pinentry="$(command -v pinentry || true)"

      [ -n "$pinentry" ] \
        || die "no pinentry configured for gpg-agent (set programs.gnupg.agent.pinentryPackage)"
      [ -x "$pinentry" ] \
        || die "configured pinentry '$pinentry' is not executable (stale ~/.gnupg/gpg-agent.conf?)"

      exec ${pkgs.python3}/bin/python3 "${pkgs.neomutt}/share/neomutt/oauth2/mutt_oauth2.py" "$@"
    '')

    # Provides libstdc++.so.6 for prebuilt (non-Nix) binaries; see enterShell.
    pkgs.stdenv.cc.cc.lib
  ];

  # ---------------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------------
  # Declared in secretspec.toml, resolved by secretspec from the provider
  # configured in devenv.yaml.
  #   PORTKEY_API_KEY : API key for the Portkey AI gateway (used by pi)
  #   LG_COORDINATOR  : LabGrid coordinator address (used by labgrid-client)
  env.LG_COORDINATOR = secretspec.secrets.LG_COORDINATOR;
  env.PORTKEY_API_KEY = secretspec.secrets.PORTKEY_API_KEY;

  # ---------------------------------------------------------------------------
  # Shell initialisation
  # ---------------------------------------------------------------------------
  enterShell = ''
    # Let prebuilt binaries (e.g. vendor tools) find libstdc++.
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    echo "###############################################################################"
    echo "# Run 'uboot-fhs' to enter the ARM64 U-Boot cross-compile FHS sandbox."
    echo "# Run 'buildroot-fhs' to enter the FHS sandbox before running Buildroot make."
    echo "# Run 'linux-fhs' to enter the FHS sandbox before running kernel make."
    echo "###############################################################################"
  '';
}
