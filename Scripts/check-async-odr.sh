#!/usr/bin/env bash
#
# Checks the objects of a native-build-system build for weak async functions
# whose copies disagree on their async context size.
#
# Swift emits a specialization of an `@_alwaysEmitIntoClient`/`@inlinable`
# async function (e.g. `Clock.sleep(for:)` for `ContinuousClock`) into every
# module that uses it. Each copy is a weak symbol, plus a weak "async function
# pointer" (mangled suffix `Tu`) that records how big a context callers
# allocate for it. Modules compiled at different deployment targets can
# produce different code for the same symbol. ld chooses the body and the
# pointer separately (it prefers the more aligned copy, then the first). A
# smaller pointer can then pair with a body that needs more room. That body
# overruns the task allocator, and the runtime aborts with "freed pointer was
# not the last allocation". Details: docs/native-build-async-odr.md.
#
# Swift Build (the default build system) links each module into one object
# first, which keeps every module's copies local. So only the native build
# system is exposed, and only its objects are checked here.
#
# Usage:
#   bash Scripts/check-async-odr.sh [--build] [objects-dir]
#
#   --build      run `swift build -c release --build-system native` first
#   objects-dir  default .build/<arch>-apple-macosx/release
#
# Exit status: 0 no mismatch, 1 at least one weak async function pointer has
# different context sizes in different objects, 2 usage/build error.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build=0
dir=""
for arg in "$@"; do
    case "$arg" in
        --build) build=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) dir="$arg" ;;
    esac
done

if [[ -z "$dir" ]]; then
    dir="$repo_root/.build/$(uname -m)-apple-macosx/release"
fi

if [[ "$build" == 1 ]]; then
    (cd "$repo_root" && swift build -c release --build-system native) || exit 2
fi

if [[ ! -d "$dir" ]]; then
    echo "error: no objects directory at $dir (build with --build first)" >&2
    exit 2
fi

python3 - "$dir" <<'PY'
import os
import struct
import subprocess
import sys
from collections import defaultdict

root = sys.argv[1]
N_STAB, N_TYPE, N_SECT, N_WEAK_DEF = 0xE0, 0x0E, 0x0E, 0x0080
LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2


def weak_afps(path):
    """Yields (symbol, context size) for every weak async function pointer
    defined in a 64-bit Mach-O relocatable object."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    sections = [None]  # n_sect is 1-based
    symtab = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            s = off + 72
            for _ in range(nsects):
                addr, size, fileoff = struct.unpack_from("<QQI", data, s + 32)
                sections.append((addr, size, fileoff))
                s += 80
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize
    if symtab is None:
        return
    symoff, nsyms, stroff, strsize = symtab
    for i in range(nsyms):
        strx, ntype, nsect, ndesc, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
        if ntype & N_STAB or (ntype & N_TYPE) != N_SECT or not ndesc & N_WEAK_DEF:
            continue
        end = data.index(b"\0", stroff + strx)
        name = data[stroff + strx:end].decode("utf-8", "replace")
        if not name.endswith("Tu") or not name.startswith("_$s"):
            continue
        addr, size, fileoff = sections[nsect]
        if not (addr <= value < addr + size) or not fileoff:
            continue
        context = struct.unpack_from("<I", data, fileoff + (value - addr) + 4)[0]
        yield name, context


sizes = defaultdict(lambda: defaultdict(list))
objects = 0
for dirpath, _, files in os.walk(root):
    for name in files:
        if name.endswith(".o"):
            path = os.path.join(dirpath, name)
            objects += 1
            for symbol, context in weak_afps(path):
                sizes[symbol][context].append(os.path.relpath(path, root))

if objects == 0:
    print(f"error: no object files under {root}", file=sys.stderr)
    sys.exit(2)

mismatched = {s: by for s, by in sizes.items() if len(by) > 1}


def demangle(symbols):
    try:
        out = subprocess.run(["xcrun", "swift-demangle", "--simplified"],
                             input="\n".join(symbols), capture_output=True,
                             text=True, check=True).stdout.splitlines()
        return dict(zip(symbols, out))
    except (OSError, subprocess.CalledProcessError):
        return {s: s for s in symbols}


names = demangle(sorted(mismatched))
for symbol in sorted(mismatched):
    print(f"MISMATCH {names[symbol]}")
    print(f"         {symbol}")
    for context, paths in sorted(mismatched[symbol].items()):
        shown = ", ".join(sorted(paths)[:4]) + (" ..." if len(paths) > 4 else "")
        print(f"         context {context:4} bytes: {shown}")
print(f"checked {objects} objects, {len(sizes)} weak async function pointers: "
      f"{len(mismatched)} with differing context sizes")
sys.exit(1 if mismatched else 0)
PY
