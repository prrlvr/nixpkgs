# Type aliases
# Release = {
#  version: String
#  hash: String
#  supportedGpuTargets: List String
# }

{ blas
, cmake
, cudaPackages
  # FIXME: cuda being unfree means ofborg won't eval "magma".
  # respecting config.cudaSupport -> false by default
  # -> ofborg eval -> throws "no GPU targets specified".
  # Probably should delete everything but "magma-cuda" and "magma-hip"
  # from all-packages.nix
, cudaSupport ? true
, fetchurl
, gfortran
, cudaCapabilities ? cudaPackages.cudaFlags.cudaCapabilities
, gpuTargets ? [ ] # Non-CUDA targets, that is HIP
, hip
, hipblas
, hipsparse
, lapack
, lib
, libpthreadstubs
, magmaRelease
, ninja
, openmp
, rocmSupport ? false
, stdenv
, symlinkJoin
}:


let
  inherit (lib) lists strings trivial;
  inherit (cudaPackages) cudatoolkit cudaFlags cudaVersion;
  inherit (magmaRelease) version hash supportedGpuTargets;

  # NOTE: The lists.subtractLists function is perhaps a bit unintuitive. It subtracts the elements
  #   of the first list *from* the second list. That means:
  #   lists.subtractLists a b = b - a

  # For ROCm
  # NOTE: The hip.gpuTargets are prefixed with "gfx" instead of "sm" like cudaFlags.realArches.
  #   For some reason, Magma's CMakeLists.txt file does not handle the "gfx" prefix, so we must
  #   remove it.
  rocmArches = lists.map (x: strings.removePrefix "gfx" x) hip.gpuTargets;
  supportedRocmArches = lists.intersectLists rocmArches supportedGpuTargets;
  unsupportedRocmArches = lists.subtractLists supportedRocmArches rocmArches;

  supportedCustomGpuTargets = lists.intersectLists gpuTargets supportedGpuTargets;
  unsupportedCustomGpuTargets = lists.subtractLists supportedCustomGpuTargets gpuTargets;

  # Use trivial.warnIf to print a warning if any unsupported GPU targets are specified.
  gpuArchWarner = supported: unsupported:
    trivial.throwIf (supported == [ ])
      (
        "No supported GPU targets specified. Requested GPU targets: "
        + strings.concatStringsSep ", " unsupported
      )
      supported;

  gpuTargetString = strings.concatStringsSep "," (
    if gpuTargets != [ ] then
    # If gpuTargets is specified, it always takes priority.
      gpuArchWarner supportedCustomGpuTargets unsupportedCustomGpuTargets
    else if rocmSupport then
      gpuArchWarner supportedRocmArches unsupportedRocmArches
    else if cudaSupport then
      [ ] # It's important we pass explicit -DGPU_TARGET to reset magma's defaults
    else
      throw "No GPU targets specified"
  );

  # E.g. [ "80" "86" "90" ]
  cudaArchitectures = (builtins.map cudaFlags.dropDot cudaCapabilities);

  cudaArchitecturesString = strings.concatStringsSep ";" cudaArchitectures;
  minArch =
    let
      minArch' = builtins.head (builtins.sort builtins.lessThan cudaArchitectures);
    in
    # If this fails some day, something must've changed and we should re-validate our assumptions
    assert builtins.stringLength minArch' == 2;
    # "75" -> "750"  Cf. https://bitbucket.org/icl/magma/src/f4ec79e2c13a2347eff8a77a3be6f83bc2daec20/CMakeLists.txt#lines-273
    "${minArch'}0";


  cuda_joined = symlinkJoin {
    name = "cuda-redist-${cudaVersion}";
    paths = with cudaPackages; [
      cuda_nvcc
      cuda_cudart # cuda_runtime.h
      libcublas
      libcusparse
      cuda_nvprof # <cuda_profiler_api.h>
    ];
  };
in

assert (builtins.match "[^[:space:]]*" gpuTargetString) != null;

stdenv.mkDerivation {
  pname = "magma";
  inherit version;

  src = fetchurl {
    name = "magma-${version}.tar.gz";
    url = "https://icl.cs.utk.edu/projectsfiles/magma/downloads/magma-${version}.tar.gz";
    inherit hash;
  };

  nativeBuildInputs = [
    cmake
    ninja
    gfortran
  ];

  buildInputs = [
    libpthreadstubs
    lapack
    blas
  ] ++ lists.optionals cudaSupport [
    cuda_joined
  ] ++ lists.optionals rocmSupport [
    hip
    hipblas
    hipsparse
    openmp
  ];

  cmakeFlags = [
    "-DGPU_TARGET=${gpuTargetString}"
  ] ++ lists.optionals cudaSupport [
    "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchitecturesString}"
    "-DMIN_ARCH=${minArch}" # Disarms magma's asserts
    "-DCMAKE_C_COMPILER=${cudatoolkit.cc}/bin/cc"
    "-DCMAKE_CXX_COMPILER=${cudatoolkit.cc}/bin/c++"
    "-DMAGMA_ENABLE_CUDA=ON"
  ] ++ lists.optionals rocmSupport [
    "-DCMAKE_C_COMPILER=${hip}/bin/hipcc"
    "-DCMAKE_CXX_COMPILER=${hip}/bin/hipcc"
    "-DMAGMA_ENABLE_HIP=ON"
  ];

  # NOTE: The stdenv's CXX is used when compiling the CMake test to determine the version of
  #   CUDA available. This isn't necessarily the same as cudatoolkit.cc, so we must set
  #   CUDAHOSTCXX.
  preConfigure = strings.optionalString cudaSupport ''
    export CUDAHOSTCXX=${cudatoolkit.cc}/bin/c++
  '';

  buildFlags = [
    "magma"
    "magma_sparse"
  ];

  doCheck = false;

  passthru = {
    inherit cudaPackages cudaSupport;
  };

  meta = with lib; {
    description = "Matrix Algebra on GPU and Multicore Architectures";
    license = licenses.bsd3;
    homepage = "http://icl.cs.utk.edu/magma/index.html";
    platforms = platforms.unix;
    maintainers = with maintainers; [ tbenst ];
    # CUDA and ROCm are mutually exclusive
    broken = cudaSupport && rocmSupport || cudaSupport && strings.versionOlder cudaVersion "9";
  };
}
