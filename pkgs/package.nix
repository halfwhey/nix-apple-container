{
  lib,
  stdenv,
  fetchurl,
  xar,
  cpio,
  version ? "1.0.0",
  hash ? "sha256-E/RfJtqUw1Sty+/h6PdjHn8SbpPF1N1qWlOKpmtPR50=",
}:

stdenv.mkDerivation {
  pname = "apple-container";
  inherit version;

  src = fetchurl {
    url = "https://github.com/apple/container/releases/download/${version}/container-${version}-installer-signed.pkg";
    inherit hash;
  };

  nativeBuildInputs = [
    xar
    cpio
  ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    xar -xf $src
    gunzip -dc Payload | cpio -i
  '';

  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp -a bin/container bin/container-apiserver $out/bin/
    cp -a libexec/container $out/libexec/
  '';

  # Apple-signed binaries — strip/fixup would break code signature
  dontFixup = true;

  meta = with lib; {
    description = "Apple's native container runtime for macOS";
    homepage = "https://github.com/apple/container";
    license = licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "container";
  };
}
