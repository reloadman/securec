#!/usr/bin/env bash

# Build libsecurec for all available OpenIPC toolchains.
# Usage:
#   ./build.sh [platform] [debug]
#   PLATFORM       – optional toolchain directory name under $TOOLCHAIN_ROOT
#   debug          – build with debug flags (otherwise release)

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")" && pwd)
SRC_DIR="$PROJECT_ROOT/src"
INCLUDE_DIR="$PROJECT_ROOT/include"
OUTPUT_ROOT="${OUTPUT_ROOT:-$PROJECT_ROOT/builds}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$HOME/openipc/toolchain}"
TARGET_PLATFORM="${1:-}"
BUILD_MODE="${2:-release}"

CFLAGS_BASE="-Wall -Wextra -fPIC -I${INCLUDE_DIR}"
if [ "$BUILD_MODE" = "debug" ]; then
    CFLAGS="${CFLAGS_BASE} -O0 -g"
    STRIP_OUTPUT=false
else
    CFLAGS="${CFLAGS_BASE} -Os -pipe"
    STRIP_OUTPUT=true
fi
LDFLAGS="-shared -Wl,-soname,libsecurec.so"

if [ ! -d "$SRC_DIR" ]; then
    echo "Missing source directory: $SRC_DIR" >&2
    exit 1
fi
if [ ! -d "$TOOLCHAIN_ROOT" ]; then
    echo "Toolchain directory not found: $TOOLCHAIN_ROOT" >&2
    exit 1
fi

mapfile -t SRCS < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.c' | sort)
if [ ${#SRCS[@]} -eq 0 ]; then
    echo "No source files found in $SRC_DIR" >&2
    exit 1
fi

discover_toolchains() {
    local list=""
    for dir in "$TOOLCHAIN_ROOT"/*; do
        [ -d "$dir" ] || continue
        local gcc_bin
    gcc_bin=$(find "$dir" -maxdepth 3 \( -path "*/bin/*-gcc" -o -path "*/host/bin/*-gcc" \) \( -type f -o -type l \) 2>/dev/null | head -n1 || true)
        [ -n "$gcc_bin" ] || continue
        local prefix
        prefix=$(basename "$gcc_bin")
        prefix=${prefix%-gcc}
        local name
        name=$(basename "$dir")
        list+="${name}:${prefix}"$'\n'
    done
    printf "%s" "$list"
}

TOOLCHAIN_PAIRS="${TOOLCHAIN_PAIRS:-$(discover_toolchains | sort)}"
if [ -z "$TOOLCHAIN_PAIRS" ]; then
    echo "No toolchains found under $TOOLCHAIN_ROOT" >&2
    echo "Searched for *-gcc under */bin and */host/bin. Set TOOLCHAIN_PAIRS or TOOLCHAIN_ROOT explicitly." >&2
    exit 1
fi

if [ -n "$TARGET_PLATFORM" ]; then
    selected=""
    while IFS= read -r pair; do
        [ -z "$pair" ] && continue
        name=${pair%%:*}
        if [ "$name" = "$TARGET_PLATFORM" ]; then
            selected="$pair"
            break
        fi
    done <<<"$TOOLCHAIN_PAIRS"

    if [ -z "$selected" ]; then
        echo "Platform not found: $TARGET_PLATFORM" >&2
        exit 1
    fi
    TOOLCHAIN_PAIRS="$selected"
fi

build_one() {
    local platform="$1"
    local prefix="$2"
    local dir="$TOOLCHAIN_ROOT/$platform"
    local cc="$dir/bin/${prefix}-gcc"
    local ar="$dir/bin/${prefix}-ar"
    local strip_bin="$dir/bin/${prefix}-strip"

    if [ ! -x "$cc" ]; then
        echo "Compiler not found: $cc" >&2
        return 1
    fi
    if [ ! -x "$ar" ]; then
        echo "Archiver not found: $ar" >&2
        return 1
    fi

    echo "==> Building securec for ${platform} (${prefix})"

    local work
    work=$(mktemp -d "$PROJECT_ROOT/.build-${platform}.XXXXXX")
    trap 'rm -rf "$work"' EXIT

    for src in "${SRCS[@]}"; do
        local obj="$work/$(basename "${src%.c}.o")"
        "$cc" $CFLAGS -c "$src" -o "$obj"
    done

    mkdir -p "$OUTPUT_ROOT/$platform"
    "$ar" rcs "$OUTPUT_ROOT/$platform/libsecurec.a" "$work"/*.o
    "$cc" $CFLAGS $LDFLAGS "$work"/*.o -o "$OUTPUT_ROOT/$platform/libsecurec.so"

    if $STRIP_OUTPUT && [ -x "$strip_bin" ]; then
        "$strip_bin" "$OUTPUT_ROOT/$platform/libsecurec.so" >/dev/null 2>&1 || true
    fi

    echo "   -> $OUTPUT_ROOT/$platform/libsecurec.a"
    echo "   -> $OUTPUT_ROOT/$platform/libsecurec.so"

    rm -rf "$work"
    trap - EXIT
}

while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    platform=${pair%%:*}
    prefix=${pair#*:}
    build_one "$platform" "$prefix"
done <<<"$TOOLCHAIN_PAIRS"
