{
  stdenv,
  cacert,
  curl,
  zstd,
  gnutar,
  version ? "3.26.0",
  hash ? "sha256-Y+LzuhkEwPlEGDUW4xtN6sCcIELOm+3x9V18XpRA/1Y=",
}:

stdenv.mkDerivation {
  pname = "kata-kernel";
  inherit version;

  outputHash = hash;
  outputHashMode = "flat";

  nativeBuildInputs = [
    cacert
    curl
    zstd
    gnutar
  ];

  buildCommand = ''
    curl -L -o kata.tar.zst "https://github.com/kata-containers/kata-containers/releases/download/${version}/kata-static-${version}-arm64.tar.zst"
    tar --zstd -xf kata.tar.zst ./opt/kata/share/kata-containers/
    cp -L ./opt/kata/share/kata-containers/vmlinux.container $out
  '';
}
