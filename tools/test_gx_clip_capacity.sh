#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-clip-capacity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
python3 - "$repo" "$tmp" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);o=Path(sys.argv[2]);s=(r/'third_party/melonDS/src/GPU3D.cpp').read_text()
a=s.index('template<int comp, s32 plane, bool attribs>\nvoid ClipSegment(')
b=s.index('template<bool attribs>\nint ClipPolygon(',a)
code=s[a:b].replace('const GPU3D& gpu','const TestGPU& gpu')
assert code.count('c < MaxClipVertices')==6
prefix='''#include "GPU3D.h"
#include "NDS4MiSTer_GXClipMath.h"
#include <algorithm>
#include <cstdlib>
'''
stub='''using namespace melonDS;
struct TestGPU { unsigned CurPolygonAttr; };
static u64 NDS4MiSTerClipInterp=0, NDS4MiSTerClipZeroDen=0;
enum class LogLevel { Error };
template<typename... T> void Log(LogLevel,const char*,T...) { std::abort(); }
'''
ref=code.replace('MaxClipVertices = 10','MaxClipVertices = 256')
ref=ref.replace('nverts = c; c = clipstart;', 'peak = std::max(peak, c); nverts = c; c = clipstart;')
ref=ref.replace('    return c;', '    peak = std::max(peak, c); return c;')
for name,subject in [('fixed',code),('negative',code.replace(' && c < MaxClipVertices','').replace('else if (c < MaxClipVertices)','else'))]:
 text=prefix+'namespace tested {\n'+stub+subject+'}\nnamespace unbounded {\n'+stub+'static int peak=0;\n'+ref+'}\n'
 (o/(name+'.h')).write_text(text)
PY
cp "$tmp/fixed.h" "$tmp/clip_under_test.h"
c++ -std=c++17 -O2 -fwrapv -Wall -Wextra -Werror -Wno-unused-parameter -Wno-missing-braces -I"$tmp" -I"$repo/third_party/melonDS/src" "$repo/tools/test_gx_clip_capacity.cpp" -o "$tmp/test"
"$tmp/test"
c++ -std=c++17 -O1 -g -fwrapv -fno-omit-frame-pointer -fsanitize=address,undefined -I"$tmp" -I"$repo/third_party/melonDS/src" "$repo/tools/test_gx_clip_capacity.cpp" -o "$tmp/test"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$tmp/test"
cp "$tmp/negative.h" "$tmp/clip_under_test.h"
c++ -std=c++17 -O1 -g -fwrapv -fno-omit-frame-pointer -fsanitize=address -I"$tmp" -I"$repo/third_party/melonDS/src" "$repo/tools/test_gx_clip_capacity.cpp" -o "$tmp/negative"
if ASAN_OPTIONS=detect_leaks=0 "$tmp/negative" > "$tmp/negative.log" 2>&1; then
 echo 'FAIL: unbounded clipper negative control survived';exit 1
fi
grep -m1 'ERROR: AddressSanitizer: stack-buffer-overflow' "$tmp/negative.log"
echo 'PASS: clip bounds, unchanged normal output, ASan/UBSan and detecting negative control'
