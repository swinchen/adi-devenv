{ pkgs, lib }:

pkgs.stdenv.mkDerivation rec {
  pname = "adsp-ldr";
  version = "1.0.3";

  src = pkgs.fetchgit {
    url = "https://github.com/analogdevicesinc/adsp-ldr.git";
    rev = "v${version}";
    hash = "sha256-FiZWC1NUBOjNHLXrMyo1oR0iB2QB4G7pWSIiLwvcsD8=";
  };

  nativeBuildInputs = with pkgs; [
    meson
    ninja
    pkg-config
  ];

  buildInputs = [
    pkgs.libusb1
  ];

  # meson.build runs `git describe` via utils/version.sh to get the version,
  # but fetchgit strips .git. Patch it to use a fixed version string instead.
  postPatch = ''
    substituteInPlace meson.build \
      --replace-fail \
        "run_command(['utils/version.sh', 'get-vcs'], check: true).stdout().strip()" \
        "'${version}'"
  '';

  postInstall = ''
    mv $out/bin/ldr $out/bin/aarch64-unknown-linux-gnu-ldr
  '';

  meta = {
    description = "Generate boot streams for ADI ADSP processors";
    homepage = "https://github.com/analogdevicesinc/adsp-ldr";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
