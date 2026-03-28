{ stdenv, cacert, curl, zstd, gnutar }:

stdenv.mkDerivation {
  pname = "kata-kernel";
  version = "3.26.0";

  outputHash = "sha256-Y+LzuhkEwPlEGDUW4xtN6sCcIELOm+3x9V18XpRA/1Y=";
  outputHashMode = "flat";

  nativeBuildInputs = [ cacert curl zstd gnutar ];

  buildCommand = ''
    curl -L -o kata.tar.zst "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
    tar --zstd -xf kata.tar.zst ./opt/kata/share/kata-containers/
    cp -L ./opt/kata/share/kata-containers/vmlinux.container $out
  '';
}
