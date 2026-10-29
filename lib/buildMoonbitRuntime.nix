# Compile the MoonBit native runtime sources (`lib/runtime/*.c`) into
# `libruntime.a`, once per native executable. The C compiler comes from `stdenv`
# (`$CC` — the nixpkgs cc-wrapper, which resolves crt/libc correctly), the sources
# and headers from the `toolchain`.
#
# An archive rather than one relocatable object, as moon does: newer toolchains
# ship runtime sources such as `thread_pool.c` that moonbitlang/async also
# carries as a C stub, and only an archive lets the link leave the unused copy out.
#
#   moon-nix.buildMoonbitRuntime { toolchain = …; }   # → $out/libruntime.a
{ stdenv }:
{
  pname ? "moonbit-runtime",
  toolchain,
}:
stdenv.mkDerivation {
  name = pname;
  dontUnpack = true;
  phases = [ "buildPhase" ];
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    export HOME=$TMPDIR
    for source in ${toolchain}/lib/runtime/*.c; do
      $CC -o "$(basename "$source" .c).o" -I${toolchain}/include -g -c \
        -fwrapv -fno-strict-aliasing -O2 \
        -DMOONBIT_ALLOW_STACKTRACE -DMOONBIT_USE_SIMDUTF "$source"
    done
    $AR rcs $out/libruntime.a ./*.o
    runHook postBuild
  '';
}
