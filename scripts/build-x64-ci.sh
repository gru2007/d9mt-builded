#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
PREBUILT="$ROOT/prebuilt"
DIST_ROOT="$ROOT/dist"
DIST="$DIST_ROOT/d9mt-x64"
MINGW="x86_64-w64-mingw32"

for tool in curl python3 clang "$MINGW-gcc" "$MINGW-g++" "$MINGW-dlltool" "$MINGW-objdump" glslang; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

rm -rf "$BUILD/d9mtmetal" "$DIST"
mkdir -p "$BUILD/d9mtmetal" "$PREBUILT" "$DIST/x86_64-windows" "$DIST/x86_64-unix"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fetch the latest DXMT builtin release and keep only the x86_64 winemetal
# pieces. d9mt's upstream fetch script currently generates only an i686 import
# library, so CI creates the 64-bit import library below.
# ---------------------------------------------------------------------------
DXMT_REPO="${DXMT_REPO:-3Shain/dxmt}"
API="https://api.github.com/repos/${DXMT_REPO}/releases/latest"
CURL_HEADERS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_HEADERS+=(
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
fi

curl -fsSL "${CURL_HEADERS[@]}" "$API" -o "$TMP/release.json"
DXMT_TAG="$(python3 - "$TMP/release.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    print(json.load(f)['tag_name'])
PY
)"
DXMT_URL="$(python3 - "$TMP/release.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
assets = [a for a in data.get('assets', []) if a['name'].endswith('-builtin.tar.gz')]
if not assets:
    raise SystemExit('DXMT latest release has no *-builtin.tar.gz asset')
print(assets[0]['browser_download_url'])
PY
)"

echo "[x64] DXMT release: $DXMT_TAG"
curl -fsSL "$DXMT_URL" -o "$TMP/dxmt-builtin.tar.gz"
tar -tzf "$TMP/dxmt-builtin.tar.gz" > "$TMP/tar-list.txt"
WINEMETAL_DLL_PATH="$(grep -m1 -E '(^|/)x86_64-windows/winemetal\.dll$' "$TMP/tar-list.txt" || true)"
WINEMETAL_SO_PATH="$(grep -m1 -E '(^|/)x86_64-unix/winemetal\.so$' "$TMP/tar-list.txt" || true)"

if [[ -z "$WINEMETAL_DLL_PATH" || -z "$WINEMETAL_SO_PATH" ]]; then
  echo "Could not find x86_64 winemetal files in DXMT archive" >&2
  cat "$TMP/tar-list.txt" >&2
  exit 1
fi

tar -xzf "$TMP/dxmt-builtin.tar.gz" -C "$TMP" \
  "$WINEMETAL_DLL_PATH" "$WINEMETAL_SO_PATH"
cp "$TMP/$WINEMETAL_DLL_PATH" "$PREBUILT/winemetal.dll"
cp "$TMP/$WINEMETAL_SO_PATH" "$PREBUILT/winemetal.so"

# Generate a 64-bit GNU import library from winemetal.dll exports.
python3 - "$PREBUILT/winemetal.dll" "$PREBUILT/winemetal64.def" <<'PY'
import re
import subprocess
import sys

dll, out_def = sys.argv[1:]
out = subprocess.check_output(
    ['x86_64-w64-mingw32-objdump', '-p', dll],
    text=True,
    errors='replace',
)
marker = '[Ordinal/Name Pointer] Table -- Ordinal Base 1'
pos = out.find(marker)
if pos < 0:
    raise SystemExit('Name Pointer Table not found in winemetal.dll')

names = []
for line in out[pos:].splitlines()[1:]:
    if 'Base Relocations' in line or 'Relocations' in line:
        break
    m = re.match(r'\s+[0-9A-Fa-f]+\s+(\S+)\s*$', line)
    if m:
        names.append(m.group(1))

if not names:
    raise SystemExit('No exports parsed from winemetal.dll')

with open(out_def, 'w', encoding='utf-8') as f:
    f.write('LIBRARY winemetal.dll\nEXPORTS\n')
    for name in names:
        f.write(f'  {name}\n')
PY

"$MINGW-dlltool" \
  -d "$PREBUILT/winemetal64.def" \
  -l "$PREBUILT/libwinemetal64.a" \
  --dllname winemetal.dll

# ---------------------------------------------------------------------------
# Build the x86_64 d9mtmetal builtin PE + x86_64 Mach-O unixlib. This is the
# runtime bridge used by d3d9.dll for Metal calls that DXMT winemetal lacks.
# ---------------------------------------------------------------------------
D9OUT="$BUILD/d9mtmetal"
cat > "$D9OUT/ntdll-cx64.def" <<'EOF'
LIBRARY ntdll.dll
EXPORTS
  __wine_unix_call
  NtQueryVirtualMemory
EOF

"$MINGW-dlltool" \
  -d "$D9OUT/ntdll-cx64.def" \
  -l "$D9OUT/libntdll-cx64.a" \
  --dllname ntdll.dll

"$MINGW-gcc" -shared -O2 -s \
  -o "$D9OUT/d9mtmetal.dll" \
  "$ROOT/src/d9mtmetal/dll.c" \
  -I "$ROOT/src/d9mtmetal" \
  "$D9OUT/libntdll-cx64.a" \
  -Wl,--file-alignment,0x1000

python3 "$ROOT/tools/make-builtin.py" "$D9OUT/d9mtmetal.dll"

cat > "$D9OUT/d9mtmetal.def" <<'EOF'
LIBRARY d9mtmetal.dll
EXPORTS
  D9MT_UnixCall
EOF

"$MINGW-dlltool" \
  -d "$D9OUT/d9mtmetal.def" \
  -l "$D9OUT/libd9mtmetal64.a" \
  --dllname d9mtmetal.dll

clang -ObjC -dynamiclib -arch x86_64 -O2 \
  -o "$D9OUT/d9mtmetal.so" \
  "$ROOT/src/d9mtmetal/unix.m" \
  -I "$ROOT/src/d9mtmetal" \
  -install_name @rpath/d9mtmetal.so \
  -lsqlite3 \
  -framework Metal \
  -framework Foundation

# ---------------------------------------------------------------------------
# Reuse upstream's working DXVK D3D9 frontend build, but patch only the
# architecture-specific pieces in a temporary copy. The upstream i686 script
# remains untouched in the repository.
# ---------------------------------------------------------------------------
PATCHED="$BUILD/build-dxvkfe-x64.sh"
python3 - "$ROOT/scripts/build-dxvkfe.sh" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding='utf-8')
out = []
seen = {
    'cxx': False,
    'cc': False,
    'stack': False,
    'linkflags': False,
    'winemetal': False,
    'd9mtmetal': False,
}

for line in src.splitlines():
    if line == 'CXX=i686-w64-mingw32-g++':
        line = 'CXX=x86_64-w64-mingw32-g++'
        seen['cxx'] = True
    elif line == 'CC=i686-w64-mingw32-gcc':
        line = 'CC=x86_64-w64-mingw32-gcc'
        seen['cc'] = True
    elif '-mpreferred-stack-boundary=2' in line:
        # Win64 already has SSE2 in the ABI; the i686 stack boundary flag is
        # invalid/inappropriate here.
        seen['stack'] = True
        continue
    elif '-Wl,--file-alignment=4096,--enable-stdcall-fixup,--kill-at' in line:
        line = line.replace(
            '-Wl,--file-alignment=4096,--enable-stdcall-fixup,--kill-at',
            '-Wl,--file-alignment=4096',
        )
        seen['linkflags'] = True
    elif '-L "$ROOT/prebuilt" -lwinemetal' in line:
        line = line.replace('-lwinemetal', '-lwinemetal64')
        seen['winemetal'] = True
    elif '-L "$BUILD/d9mtmetal" -ld9mtmetal32' in line:
        line = line.replace('-ld9mtmetal32', '-ld9mtmetal64')
        seen['d9mtmetal'] = True
    out.append(line)

missing = [k for k, v in seen.items() if not v]
if missing:
    raise SystemExit('upstream build script changed; x64 patch points missing: ' + ', '.join(missing))

Path(sys.argv[2]).write_text('\n'.join(out) + '\n', encoding='utf-8')
PY

chmod +x "$PATCHED"
RELEASE=1 bash "$PATCHED"

# Fail CI if we accidentally produced an i686 PE.
"$MINGW-objdump" -f "$BUILD/d3d9fe.dll" | tee "$BUILD/d3d9fe-x64.txt"
grep -q 'file format pei-x86-64' "$BUILD/d3d9fe-x64.txt"
"$MINGW-objdump" -f "$D9OUT/d9mtmetal.dll" | tee "$BUILD/d9mtmetal-x64.txt"
grep -q 'file format pei-x86-64' "$BUILD/d9mtmetal-x64.txt"

# ---------------------------------------------------------------------------
# Runtime package. d3d9.dll goes beside the x64 game executable (or another
# native-DLL search location); d9mtmetal/winemetal are Wine builtins/unixlibs.
# ---------------------------------------------------------------------------
cp "$BUILD/d3d9fe.dll" "$DIST/d3d9.dll"
cp "$D9OUT/d9mtmetal.dll" "$DIST/x86_64-windows/d9mtmetal.dll"
cp "$D9OUT/d9mtmetal.so" "$DIST/x86_64-unix/d9mtmetal.so"
cp "$PREBUILT/winemetal.dll" "$DIST/x86_64-windows/winemetal.dll"
cp "$PREBUILT/winemetal.so" "$DIST/x86_64-unix/winemetal.so"

cat > "$DIST/INSTALL.txt" <<EOF
Experimental d9mt x86_64 build
Source commit: ${GITHUB_SHA:-local}
DXMT winemetal: ${DXMT_TAG}

Files:
  d3d9.dll                         native x64 D3D9 frontend; put where the game loads d3d9.dll
  x86_64-windows/d9mtmetal.dll    Wine builtin companion
  x86_64-unix/d9mtmetal.so        Wine unixlib companion
  x86_64-windows/winemetal.dll    DXMT Wine builtin
  x86_64-unix/winemetal.so        DXMT unixlib

CrossOver/Wine must load d3d9 as native and d9mtmetal/winemetal as builtins.
This package is experimental; first tests should be done offline / with -insecure.
EOF

(
  cd "$DIST_ROOT"
  find d9mt-x64 -type f ! -name SHA256SUMS | sort | while IFS= read -r f; do
    shasum -a 256 "$f"
  done > d9mt-x64/SHA256SUMS
  rm -f d9mt-x64.zip
  zip -qry d9mt-x64.zip d9mt-x64
)

echo "[x64] package ready: $DIST_ROOT/d9mt-x64.zip"
ls -lh "$DIST_ROOT/d9mt-x64.zip" "$DIST/d3d9.dll"
