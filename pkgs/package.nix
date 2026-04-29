{
  lib,
  stdenv,
  fetchurl,
  xar,
  cpio,
  version ? "0.12.1",
  hash ? "sha256-wGqcvfJnu3EJQ54o4+9e2NHToAaKbIaBa1usG/WAYwY=",
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
