#!/bin/bash
# Run from the matching MinGW shell: bash -o igncr thirdparty/build_avs.sh x64|x86
set -euo pipefail
# Upstream configure/version scripts do not support inherited nounset.
export -n SHELLOPTS

architecture=${1:-x64}
case "$architecture" in
    x64) host=x86_64-w64-mingw32; bits=64; deps_directory=deps ;;
    x86) host=i686-w64-mingw32; bits=32; deps_directory=x86-deps ;;
    *) echo "Usage: $0 x64|x86" >&2; exit 1 ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
deps_root=${LAV_AVS_DEPS_DIR:-"$repo_root/bin_build/avs-first/$deps_directory"}
prefix="$repo_root/thirdparty/$bits"
jobs=${NUMBER_OF_PROCESSORS:-8}
source <(tr -d '\r' < "$repo_root/thirdparty/avs-versions.txt")

for command in git gcc g++ make nasm cmake ninja pkg-config cygpath nm objcopy comm cmp; do
    command -v "$command" >/dev/null || { echo "Missing tool: $command" >&2; exit 1; }
done
if [[ "$(gcc -dumpmachine)" != "$host" || "$(g++ -dumpmachine)" != "$host" ]]; then
    echo "Use the $host MinGW toolchain for $architecture." >&2
    exit 1
fi
mkdir -p "$deps_root" "$prefix/include" "$prefix/lib/pkgconfig"

checkout_source() {
    local name=$1 url=$2 revision=$3 patch_file=${4:-}
    local directory="$deps_root/$name"
    local new_checkout=0
    if [[ ! -d "$directory/.git" ]]; then
        git -c core.autocrlf=false clone --no-checkout "$url" "$directory"
        new_checkout=1
    fi
    git -C "$directory" config core.autocrlf false
    git -C "$directory" remote set-url origin "$url"
    if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$directory" fetch origin "$revision"
    fi
    if [[ "$new_checkout" == 0 ]]; then
        # Only undo our exact dependency patch; never discard unrelated source edits.
        if [[ -n "$patch_file" ]] &&
            tr -d '\r' < "$patch_file" | git -C "$directory" apply --reverse --check - 2>/dev/null; then
            tr -d '\r' < "$patch_file" | git -C "$directory" apply --reverse -
        fi
        git -C "$directory" diff --quiet
        git -C "$directory" diff --cached --quiet
    fi
    git -C "$directory" checkout --detach "$revision"
    # Upstream version scripts count origin/master, so pin it to the build revision.
    git -C "$directory" update-ref refs/remotes/origin/master "$revision"
    [[ "$(git -C "$directory" rev-parse HEAD)" == "$revision" ]]
    if [[ -n "$patch_file" ]]; then
        tr -d '\r' < "$patch_file" | git -C "$directory" apply --check -
        tr -d '\r' < "$patch_file" | git -C "$directory" apply -
    fi
}

checkout_source davs2-8bit "$DAVS2_8BIT_REPOSITORY" "$DAVS2_8BIT_REVISION"
checkout_source davs2-10bit "$DAVS2_10BIT_REPOSITORY" "$DAVS2_10BIT_REVISION" \
    "$repo_root/thirdparty/davs2-patches/fixed-10bit-state.patch"
checkout_source uavs3d https://github.com/uavs3/uavs3d.git "$UAVS3D_REVISION"

# The 10-bit extension must share the official 8-bit API's exact public layout.
# Install the official header below, and fail before building if the fork drifts.
cmp -s <(tr -d '\r' < "$deps_root/davs2-8bit/source/davs2.h") \
    <(tr -d '\r' < "$deps_root/davs2-10bit/source/davs2.h") || {
    echo "davs2 8-bit/10-bit public API header mismatch" >&2; exit 1;
}

davs2_options=()
if [[ "$architecture" == x86 ]]; then
    # The pinned quant8.asm uses movq with 32-bit GPR operands; use upstream C code.
    davs2_options+=(--disable-asm)
fi

(
    cd "$deps_root/davs2-8bit/build/linux"
    if [[ -f config.mak ]]; then
        env SHELLOPTS=igncr make clean 2>&1 | tee "$deps_root/davs2-clean.log"
    fi
    env SHELLOPTS=igncr CC=g++ bash -o igncr ./configure --host="$host" --prefix="$prefix" \
        --bit-depth=8 --chroma-format=420 "${davs2_options[@]}" \
        --extra-cflags="-std=gnu++11" \
        --extra-ldflags="-static-libgcc -static-libstdc++" \
        2>&1 | tee "$deps_root/davs2-configure.log"
    env SHELLOPTS=igncr make -j"$jobs" 2>&1 | tee "$deps_root/davs2-build.log"
    env SHELLOPTS=igncr make install-lib-static 2>&1 | tee "$deps_root/davs2-install.log"
)

(
    cd "$deps_root/davs2-10bit/build/linux"
    if [[ -f config.mak ]]; then
        env SHELLOPTS=igncr make clean 2>&1 | tee "$deps_root/davs2-10bit-clean.log"
    fi
    env SHELLOPTS=igncr CC=g++ bash -o igncr ./configure --host="$host" --prefix="$prefix" \
        --bit-depth=10 --chroma-format=420 "${davs2_options[@]}" \
        --extra-cflags="-std=gnu++11" \
        --extra-ldflags="-static-libgcc -static-libstdc++" \
        2>&1 | tee "$deps_root/davs2-10bit-configure.log"
    env SHELLOPTS=igncr make -j"$jobs" lib-static 2>&1 | tee "$deps_root/davs2-10bit-build.log"

    # Namespace every definition, including C++, constants and assembly labels.
    # Undefined CRT/thread imports must retain their original external names.
    nm -g --defined-only -P libdavs2.a | awk '$2 ~ /^[A-Za-z]$/ {print $1}' | LC_ALL=C sort -u \
        > "$deps_root/davs2-10bit-symbols.txt"
    awk '
        /^davs2_decoder_(open|send_packet|recv_frame|flush|frame_unref|close)$/ {
            print $0, "lav_davs2_10_" substr($0, 7); next
        }
        /^_davs2_decoder_(open|send_packet|recv_frame|flush|frame_unref|close)$/ {
            print $0, "_lav_davs2_10_" substr($0, 8); next
        }
        {print $0, "lav_davs2_10_" $0}
    ' "$deps_root/davs2-10bit-symbols.txt" > "$deps_root/davs2-10bit-redefine.txt"
    objcopy --redefine-syms="$deps_root/davs2-10bit-redefine.txt" libdavs2.a "$prefix/lib/libdavs2_10.a"
    nm -g --defined-only -P "$prefix/lib/libdavs2_10.a" | awk '$2 ~ /^[A-Za-z]$/ {print $1}' | LC_ALL=C sort -u \
        > "$deps_root/davs2-10bit-installed-symbols.txt"
    nm -g --defined-only -P "$prefix/lib/libdavs2.a" | awk '$2 ~ /^[A-Za-z]$/ {print $1}' | LC_ALL=C sort -u \
        > "$deps_root/davs2-8bit-installed-symbols.txt"
    LC_ALL=C comm -12 "$deps_root/davs2-8bit-installed-symbols.txt" "$deps_root/davs2-10bit-installed-symbols.txt" \
        > "$deps_root/davs2-symbol-collisions.txt"
    [[ ! -s "$deps_root/davs2-symbol-collisions.txt" ]] || { echo "davs2 archive symbol collision" >&2; exit 1; }
    api_prefix=lav_davs2_10_decoder_
    [[ "$architecture" != x86 ]] || api_prefix=_$api_prefix
    for api in open send_packet recv_frame flush frame_unref close; do
        grep -Fx "$api_prefix$api" "$deps_root/davs2-10bit-installed-symbols.txt" >/dev/null || exit 1
    done
)
cp "$repo_root/thirdparty/davs2_10.h" "$prefix/include/davs2_10.h"

(
    # The upstream CMake version script reads Git history from the working directory.
    cd "$deps_root/uavs3d"
    env SHELLOPTS=igncr cmake -S . -B "build/lav-$architecture" -G Ninja \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCOMPILE_10BIT=1 \
        -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_INSTALL_PREFIX="$(cygpath -am "$prefix")" \
        -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
        2>&1 | tee "$deps_root/uavs3d-configure.log"
    cmake --build "build/lav-$architecture" --parallel "$jobs" \
        2>&1 | tee "$deps_root/uavs3d-build.log"
    cmake --install "build/lav-$architecture" 2>&1 | tee "$deps_root/uavs3d-install.log"
)

davs2_version=$(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/davs2.pc" | tr -d '\r')
uavs3d_version=$(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/uavs3d.pc" | tr -d '\r')

# Installed text artifacts follow the repository's CRLF convention.
for header in davs2.h davs2_10.h davs2_config.h uavs3d.h; do
    sed 's/\r$//;s/$/\r/' "$prefix/include/$header" > "$prefix/include/$header.lav-crlf"
    mv "$prefix/include/$header.lav-crlf" "$prefix/include/$header"
done

# Relocatable metadata; explicitly close the static C++/thread runtime dependencies.
cat <<EOF | sed 's/$/\r/' > "$prefix/lib/pkgconfig/davs2.pc"
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: davs2
Description: AVS2 isolated 8-bit and 10-bit decoder libraries
Version: $davs2_version
Libs: -L\${libdir} -ldavs2 -ldavs2_10
Libs.private: -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic -static-libgcc -lm
Cflags: -I\${includedir}
EOF

cat <<EOF | sed 's/$/\r/' > "$prefix/lib/pkgconfig/uavs3d.pc"
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: uavs3d
Description: AVS3 baseline 8/10-bit decoder library
Version: $uavs3d_version
Libs: -L\${libdir} -luavs3d
Libs.private: -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic -static-libgcc -lm
Cflags: -I\${includedir}
EOF

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
pkg-config --atleast-version=1.6.0 davs2
pkg-config --atleast-version=1.1.41 uavs3d

# Symbol inventories alone cannot detect an undefined reference inside an
# archive member. Link every public entrypoint and instantiate both backends.
cat <<'EOF' | sed 's/$/\r/' > "$deps_root/davs2-api-link.c"
#include <davs2_10.h>
struct davs2_api {
    void *(*open)(davs2_param_t *);
    int (*send)(void *, davs2_packet_t *);
    int (*recv)(void *, davs2_seq_info_t *, davs2_picture_t *);
    int (*flush)(void *, davs2_seq_info_t *, davs2_picture_t *);
    void (*unref)(void *, davs2_picture_t *);
    void (*close)(void *);
};
static const struct davs2_api apis[] = {
    {davs2_decoder_open, davs2_decoder_send_packet, davs2_decoder_recv_frame,
     davs2_decoder_flush, davs2_decoder_frame_unref, davs2_decoder_close},
    {lav_davs2_10_decoder_open, lav_davs2_10_decoder_send_packet,
     lav_davs2_10_decoder_recv_frame, lav_davs2_10_decoder_flush,
     lav_davs2_10_decoder_frame_unref, lav_davs2_10_decoder_close}
};
int main(void) {
    davs2_param_t param = {0};
    unsigned i;
    param.threads = 1;
    param.info_level = 3;
    for (i = 0; i < sizeof(apis) / sizeof(apis[0]); ++i) {
        void *decoder = apis[i].open(&param);
        if (!decoder) return 1;
        apis[i].close(decoder);
    }
    return 0;
}
EOF
gcc -std=c99 "$deps_root/davs2-api-link.c" -o "$deps_root/davs2-api-link.exe" \
    $(pkg-config --cflags --static --libs davs2) 2>&1 | tee "$deps_root/davs2-api-link-build.log"
"$deps_root/davs2-api-link.exe" 2>&1 | tee "$deps_root/davs2-api-link-run.log"
pkg-config --modversion davs2 uavs3d
pkg-config --static --libs davs2 uavs3d
echo "AVS static dependencies installed in $prefix"
