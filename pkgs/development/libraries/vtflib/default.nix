{ stdenv
, lib
, cmake
, pkgconfig
, libGL
, fetchFromGitHub
}:

stdenv.mkDerivation rec {
  pname = "vtflib";
  version = "master";

  src = fetchFromGitHub {
    rev = version;
    owner = "panzi";
    repo = "vtflib";
    sha256 = "sha256-byWqe+INjwD3AXW/Bz8jfk3+aWnnJ7PIfyNF3QUBl1g=";
  };

  buildInputs = [
    libGL
  ];

  nativeBuildInputs = [
    cmake
    pkgconfig
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"

    # TODO: need libtxc-dxtn package
    "-DUSE_LIBTXC_DXTN=OFF"
  ];

  postInstall = ''
    ln -s $out/lib/pkgconfig/VTFLib*.pc $out/lib/pkgconfig/VTFLib.pc
  '';

  enableParallelBuilding = true;

  meta = {
    homepage = "https://github.com/panzi/vtflib";
    description = "Linux port of VTFLib";
    license = lib.licenses.gpl2;
  };
}
