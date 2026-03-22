{ lib, stdenv, fetchurl, xar, cpio }:

stdenv.mkDerivation rec {
  pname = "apple-container";
  version = "0.10.0";

  src = fetchurl {
    url =
      "https://github.com/apple/container/releases/download/${version}/container-${version}-installer-signed.pkg";
    hash = "sha256-xIHONVUk0DbDzdrH/SgeMXlNQGkL+aIfcy7z12+p/gg=";
  };

  nativeBuildInputs = [ xar cpio ];

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
