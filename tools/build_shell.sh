#!/bin/sh
# Compile the washy shell (priv/shell/sh.c) → a wasm32-wasip1 command module run by TinyLasers.Wasm.
#
# "bash in WASM": a no-fork shell — pipelines are buffered chaining in one process (no fork/exec),
# builtins are compiled in, files go over the /work preopen (→ TinyLasers.Wasm.VFS, BEAM-resident).
# This is the emulation thesis as a runnable artifact.
#
# Needs an LLVM clang with the wasm32 target + a wasi sysroot. The bundled wasi-sdk works out of the
# box (clang + sysroot + resource-dir in one). Override CLANG to use your own.
#
#   sh tools/build_shell.sh
#   CLANG=/opt/homebrew/opt/llvm/bin/clang sh tools/build_shell.sh   # (then also pass --sysroot etc.)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/priv/shell/sh.c"
OUT="$ROOT/test/conformance/shell/washy_sh.wasm"

# Default: the wasi-sdk vendored under the monorepo's nexus/compilers (clang bundles its own sysroot).
CLANG="${CLANG:-$ROOT/../nexus/compilers/rust/mrustc-root/wasi-sdk-33.0-arm64-macos/bin/clang}"

if [ ! -x "$CLANG" ]; then
  echo "clang not found at: $CLANG" >&2
  echo "set CLANG=<an llvm clang with wasm32 + wasi sysroot>" >&2
  exit 1
fi

echo "compiling $SRC → $OUT"
"$CLANG" --target=wasm32-wasip1 -O1 "$SRC" -o "$OUT"
echo "ok: $(wc -c < "$OUT") bytes"
