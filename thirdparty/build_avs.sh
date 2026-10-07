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

for command in git gcc g++ make nasm cmake ninja pkg-config cygpath; do
    command -v "$command" >/dev/null || { echo "Missing tool: $command" >&2; exit 1; }
done
if [[ "$(gcc -dumpmachine)" != "$host" || "$(g++ -dumpmachine)" != "$host" ]]; then
    echo "Use the $host MinGW toolchain for $architecture." >&2
    exit 1
fi
mkdir -p "$deps_root" "$prefix/include" "$prefix/lib/pkgconfig"

checkout_source() {
    local name=$1 url=$2 revision=$3
    local directory="$deps_root/$name"
    local new_checkout=0
    if [[ ! -d "$directory/.git" ]]; then
        git -c core.autocrlf=false clone --no-checkout "$url" "$directory"
        new_checkout=1
    fi
    git -C "$directory" config core.autocrlf false
    if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$directory" fetch origin "$revision"
    fi
    if [[ "$new_checkout" == 0 ]]; then
        git -C "$directory" diff --quiet
        git -C "$directory" diff --cached --quiet
    fi
    git -C "$directory" checkout --detach "$revision"
    # Upstream version scripts count origin/master, so pin it to the build revision.
    git -C "$directory" update-ref refs/remotes/origin/master "$revision"
    [[ "$(git -C "$directory" rev-parse HEAD)" == "$revision" ]]
}

checkout_source davs2 https://github.com/pkuvcl/davs2.git "$DAVS2_REVISION"
checkout_source uavs3d https://github.com/uavs3/uavs3d.git "$UAVS3D_REVISION"

davs2_options=()
if [[ "$architecture" == x86 ]]; then
    # The pinned quant8.asm uses movq with 32-bit GPR operands; use upstream C code.
    davs2_options+=(--disable-asm)
fi

(
    cd "$deps_root/davs2/build/linux"
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
for header in davs2.h davs2_config.h uavs3d.h; do
    sed 's/\r$//;s/$/\r/' "$prefix/include/$header" > "$prefix/include/$header.lav-crlf"
    mv "$prefix/include/$header.lav-crlf" "$prefix/include/$header"
done

# Relocatable metadata; explicitly close the static C++/thread runtime dependencies.
cat <<EOF | sed 's/$/\r/' > "$prefix/lib/pkgconfig/davs2.pc"
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: davs2
Description: AVS2 8-bit decoder library
Version: $davs2_version
Libs: -L\${libdir} -ldavs2
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
pkg-config --modversion davs2 uavs3d
pkg-config --static --libs davs2 uavs3d
echo "AVS static dependencies installed in $prefix"
