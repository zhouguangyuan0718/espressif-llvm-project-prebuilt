#!/bin/bash
# Espressif LLVM Cross-Platform Release Builder
# Usage: ./release.sh <platform>
# Based on the working Makefile and build script

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/toolchain.env"

TAG="${TAG:-$ESP_LLVM_PAYLOAD_VERSION}"
VERSION_STRING="$TAG"
LLVM_PROJECTDIR="${LLVM_PROJECTDIR:-llvm-project}"
BUILD_DIR_BASE="${BUILD_DIR_BASE:-build}"
LLVM_REF="${LLVM_REF:-$ESP_LLVM_SOURCE_REF}"
LLVM_EXPECTED_VERSION="${LLVM_EXPECTED_VERSION:-$ESP_LLVM_EXPECTED_VERSION}"
LLVM_EXPECTED_MAJOR="${LLVM_EXPECTED_VERSION%%.*}"
LLVM_SOURCE_REVISION=""
LLVM_SOURCE_PATCH_SHA256=""

# Resolve source and build roots before changing into the per-platform build
# directory. This keeps local qualification builds isolated from the checkout
# and makes absolute paths behave the same way as the workflow defaults.
if [[ "$LLVM_PROJECTDIR" != /* ]]; then
    LLVM_PROJECTDIR="$SCRIPT_DIR/$LLVM_PROJECTDIR"
fi
if [[ "$BUILD_DIR_BASE" != /* ]]; then
    BUILD_DIR_BASE="$SCRIPT_DIR/$BUILD_DIR_BASE"
fi

# Detect host system
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]] || [[ -n "${WINDIR:-}" ]]; then
    HOST_OS="Windows_NT"
else
    HOST_OS="$(uname -s)"
fi

# Set macOS SDK root if on macOS
if [[ "$HOST_OS" == "Darwin" ]]; then
    if [[ -z "${SDKROOT:-}" ]]; then
        detected_sdkroot="$(xcrun --show-sdk-path)"
        export SDKROOT="$detected_sdkroot"
        echo "Setting SDKROOT to: $SDKROOT"
    fi
fi

# Supported build targets (native builds only)
VALID_TARGETS="aarch64-apple-darwin aarch64-linux-gnu x86_64-apple-darwin x86_64-linux-gnu"

# Function to show usage
show_usage() {
    echo "Espressif LLVM Cross-Platform Release Builder"
    echo ""
    echo "Usage: $0 <platform>"
    echo ""
    echo "Supported platforms:"
    for target in $VALID_TARGETS; do
        echo "  - $target"
    done
    echo ""
    echo "Environment variables:"
    echo "  TAG              - Payload version (default: $TAG)"
    echo "  LLVM_REF         - Exact Espressif LLVM tag/ref (default: $LLVM_REF)"
    echo "  LLVM_EXPECTED_VERSION - llvm-config version prefix (default: $LLVM_EXPECTED_VERSION)"
    echo "  LLVM_PROJECTDIR  - LLVM source directory (default: $LLVM_PROJECTDIR)"
    echo "  BUILD_DIR_BASE   - Build directory base (default: $BUILD_DIR_BASE)"
    echo ""
}

# Function to download LLVM source
download_llvm_source() {
    if [[ ! -d "$LLVM_PROJECTDIR" ]]; then
        echo "Cloning LLVM project ref $LLVM_REF..."
        git clone --branch "$LLVM_REF" --depth=1 https://github.com/espressif/llvm-project "$LLVM_PROJECTDIR"
    else
        local current_ref
        current_ref="$(git -C "$LLVM_PROJECTDIR" describe --tags --exact-match 2>/dev/null || true)"
        if [[ "$current_ref" != "$LLVM_REF" ]]; then
            echo "Error: $LLVM_PROJECTDIR is at '${current_ref:-an untagged revision}', expected $LLVM_REF" >&2
            echo "Use a fresh LLVM_PROJECTDIR instead of silently reusing different LLVM sources." >&2
            return 1
        fi
        echo "LLVM project directory already contains $LLVM_REF."
    fi
    LLVM_SOURCE_REVISION="$(git -C "$LLVM_PROJECTDIR" rev-parse HEAD)"

    local patch_path
    local patch_files=()
    for patch_path in $ESP_LLVM_PATCHES; do
        local absolute_patch="$SCRIPT_DIR/$patch_path"
        if [[ ! -f "$absolute_patch" ]]; then
            echo "Error: LLVM source patch not found: $patch_path" >&2
            return 1
        fi
        if git -C "$LLVM_PROJECTDIR" apply --check "$absolute_patch" 2>/dev/null; then
            echo "Applying LLVM source patch: $patch_path"
            git -C "$LLVM_PROJECTDIR" apply "$absolute_patch"
        elif git -C "$LLVM_PROJECTDIR" apply --reverse --check "$absolute_patch" 2>/dev/null; then
            echo "LLVM source patch is already applied: $patch_path"
        else
            echo "Error: LLVM source patch does not apply cleanly: $patch_path" >&2
            return 1
        fi
        patch_files+=("$absolute_patch")
    done

    if command -v sha256sum >/dev/null 2>&1; then
        LLVM_SOURCE_PATCH_SHA256="$(cat "${patch_files[@]}" | sha256sum | cut -d' ' -f1)"
    else
        LLVM_SOURCE_PATCH_SHA256="$(cat "${patch_files[@]}" | shasum -a 256 | cut -d' ' -f1)"
    fi
}

# Base CMake arguments - common to all platforms
get_base_cmake_args() {
    cat << 'EOF'
-G Ninja
-DCMAKE_BUILD_TYPE=Release
-DLLVM_INCLUDE_TESTS=OFF
-DLLVM_ENABLE_TERMINFO=OFF
-DLLVM_ENABLE_ZSTD=OFF
-DLLVM_ENABLE_Z3_SOLVER=OFF
-DLLVM_ENABLE_OCAMLDOC=OFF
-DLLVM_ENABLE_LIBXML2=OFF
-DLLVM_TOOL_CLANG_TOOLS_EXTRA_BUILD=OFF
-DCLANG_ENABLE_ARCMT=OFF
-DLLVM_TARGETS_TO_BUILD=X86;ARM;AArch64;AVR;Mips;RISCV;WebAssembly
-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Xtensa
-DLLVM_ENABLE_PROJECTS=clang;lld
-DLLVM_ENABLE_RUNTIMES=compiler-rt;libcxx;libcxxabi;libunwind
-DLLVM_POLLY_LINK_INTO_TOOLS=ON
-DLLVM_BUILD_EXTERNAL_COMPILER_RT=ON
-DLLVM_ENABLE_EH=ON
-DLLVM_ENABLE_RTTI=ON
-DLLVM_INCLUDE_DOCS=OFF
-DLLVM_INCLUDE_EXAMPLES=OFF
-DLLVM_INCLUDE_TESTS=OFF
-DLLVM_INCLUDE_BENCHMARKS=OFF
-DLLVM_BUILD_DOCS=OFF
-DLLVM_ENABLE_DOXYGEN=OFF
-DLLVM_INSTALL_UTILS=OFF
-DLLVM_ENABLE_Z3_SOLVER=OFF
-DLLVM_ENABLE_LIBEDIT=OFF
-DLLVM_OPTIMIZED_TABLEGEN=ON
-DLLVM_USE_RELATIVE_PATHS_IN_FILES=ON
-DLLVM_SOURCE_PREFIX=.
-DLIBCXX_INSTALL_MODULES=ON
-DCLANG_FORCE_MATCHING_LIBCLANG_SOVERSION=OFF
-DCOMPILER_RT_BUILD_SANITIZERS=OFF
-DCOMPILER_RT_BUILD_XRAY=OFF
-DCOMPILER_RT_BUILD_LIBFUZZER=OFF
-DCOMPILER_RT_BUILD_PROFILE=OFF
-DCOMPILER_RT_BUILD_MEMPROF=OFF
-DCOMPILER_RT_BUILD_ORC=OFF
-DCOMPILER_RT_BUILD_GWP_ASAN=OFF
-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
-DCMAKE_POSITION_INDEPENDENT_CODE=ON
-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
-DLIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=OFF
-DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON
-DLIBCXX_USE_COMPILER_RT=ON
-DLIBCXX_HAS_ATOMIC_LIB=OFF
-DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
-DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=OFF
-DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON
-DLIBCXXABI_USE_COMPILER_RT=ON
-DLIBCXXABI_USE_LLVM_UNWINDER=ON
-DLIBUNWIND_USE_COMPILER_RT=ON
-DSANITIZER_CXX_ABI=libc++
-DSANITIZER_TEST_CXX=libc++
-DLLVM_LINK_LLVM_DYLIB=ON
-DCLANG_LINK_CLANG_DYLIB=ON
-DCMAKE_STRIP=/usr/bin/strip
EOF
}

# macOS-specific CMake arguments
get_macos_cmake_args() {
    local target="$1"
    local arch

    if [[ "$target" == "aarch64-apple-darwin" ]]; then
        arch="arm64"
    else
        arch="x86_64"
    fi

    cat << EOF
-DLLVM_BUILD_LLVM_C_DYLIB=ON
-DLLVM_ENABLE_LIBCXX=ON
-DLIBCXX_PSTL_BACKEND=libdispatch
-DCMAKE_OSX_SYSROOT=$SDKROOT
-DCMAKE_OSX_ARCHITECTURES=$arch
-DLIBCXXABI_USE_SYSTEM_LIBS=ON
EOF
}

# Linux-specific CMake arguments
get_linux_cmake_args() {
    cat << 'EOF'
-DLLVM_ENABLE_LIBXML2=OFF
-DLLVM_ENABLE_LIBCXX=OFF
-DCLANG_DEFAULT_CXX_STDLIB=libstdc++
-DLLVM_BUILD_LLVM_DYLIB=ON
-DCOMPILER_RT_USE_LLVM_UNWINDER=ON
EOF
}

# Function to get platform-specific CMake arguments
get_platform_cmake_args() {
    local target="$1"

    case "$target" in
        *-apple-darwin)
            get_macos_cmake_args "$target"
            ;;
        *-linux-gnu*)
            get_linux_cmake_args
            ;;
        *)
            echo "Unknown target platform: $target" >&2
            return 1
            ;;
    esac
}

# Function to set up build environment (native builds only)
setup_build_env() {
    local target="$1"

    # All builds are native, no cross-compilation setup needed
    echo "Setting up native build environment for $target"
}

# Function to get number of CPU cores
get_cpu_cores() {
    if [[ "$HOST_OS" == "Darwin" ]]; then
        sysctl -n hw.ncpu
    elif [[ "$HOST_OS" == "Linux" ]]; then
        nproc
    elif [[ "$HOST_OS" == "Windows_NT" ]]; then
        echo "${NUMBER_OF_PROCESSORS:-4}"
    else
        echo "4"
    fi
}

# Function to create release directory structure
create_release_structure() {
    local target="$1"
    local install_dir="$2"
    local release_dir="dist/${target}/esp-clang"

    echo "Creating release structure in $release_dir..."

    # Create release directory
    rm -rf "dist/${target}"
    mkdir -p "$release_dir"

    # Copy installation files
    if [[ -d "$install_dir" ]]; then
        cp -r "$install_dir"/* "$release_dir"/
    else
        echo "Warning: Install directory $install_dir not found"
        return 1
    fi

    cat > "$release_dir/LLGO-LLVM-MANIFEST.txt" << EOF
payload_version=$VERSION_STRING
llvm_source_repository=https://github.com/espressif/llvm-project
llvm_source_ref=$LLVM_REF
llvm_source_revision=$LLVM_SOURCE_REVISION
llvm_source_patches=$ESP_LLVM_PATCHES
llvm_source_patch_sha256=$LLVM_SOURCE_PATCH_SHA256
llvm_expected_version=$LLVM_EXPECTED_VERSION
llvm_targets=X86;ARM;AArch64;AVR;Mips;RISCV;WebAssembly;Xtensa
host_target=$target
EOF

    validate_release "$release_dir"

    echo "Release directory created: $release_dir"
    echo "Contents:"
    ls -la "$release_dir"

    # Create tarball
    echo "Creating tarball package..."
    mkdir -p dist
    cd "dist/${target}"
    tar -cJf "../clang-esp-${VERSION_STRING}-${target}.tar.xz" esp-clang/
    cd - > /dev/null

    local archive="dist/clang-esp-${VERSION_STRING}-${target}.tar.xz"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$archive" > "$archive.sha256"
    else
        shasum -a 256 "$archive" > "$archive.sha256"
    fi

    echo "Tarball created: $archive"
    echo "Checksum created: $archive.sha256"
    echo "Package size: $(du -h "$archive" | cut -f1)"
}

validate_release() {
    local release_dir="$1"
    local actual_version targets tool target_name test_dir

    for tool in clang clang++ ld.lld lld llvm-ar llvm-config llvm-nm llc opt; do
        if [[ ! -x "$release_dir/bin/$tool" ]]; then
            echo "Error: required tool $tool is missing from $release_dir/bin" >&2
            return 1
        fi
    done

    actual_version="$("$release_dir/bin/llvm-config" --version)"
    if [[ "$actual_version" != "$LLVM_EXPECTED_VERSION"* ]]; then
        echo "Error: llvm-config reports $actual_version, expected $LLVM_EXPECTED_VERSION.x" >&2
        return 1
    fi

    targets="$("$release_dir/bin/llvm-config" --targets-built)"
    for target_name in X86 ARM AArch64 AVR Mips RISCV WebAssembly Xtensa; do
        if [[ " $targets " != *" $target_name "* ]]; then
            echo "Error: required LLVM target $target_name is missing: $targets" >&2
            return 1
        fi
    done

    [[ -f "$release_dir/include/llvm-c/Core.h" ]] || {
        echo "Error: llvm-c/Core.h is missing" >&2
        return 1
    }
    [[ -f "$release_dir/lib/cmake/llvm/LLVMConfig.cmake" ]] || {
        echo "Error: LLVMConfig.cmake is missing" >&2
        return 1
    }
    if ! find "$release_dir/lib" -maxdepth 1 -name "libLLVM-$LLVM_EXPECTED_MAJOR.*" -print -quit | grep -q .; then
        echo "Error: libLLVM-$LLVM_EXPECTED_MAJOR shared library is missing" >&2
        return 1
    fi

    test_dir="$(mktemp -d)"
    cat > "$test_dir/schedule-region.S" << 'EOF'
        .text
        .begin schedule
        .global schedule_region_smoke_test
schedule_region_smoke_test:
        ret
        .end schedule
EOF
    if ! "$release_dir/bin/clang" --target=xtensa -c \
        "$test_dir/schedule-region.S" -o "$test_dir/schedule-region.o"; then
        rm -rf "$test_dir"
        echo "Error: Xtensa assembler does not accept schedule regions" >&2
        return 1
    fi
    rm -rf "$test_dir"

    echo "Validated LLVM $actual_version payload with targets: $targets"
}

# Main build function (native builds only)
build_platform() {
    local target="$1"

    echo "Building LLVM for platform: $target"
    echo "Version: $VERSION_STRING"
    echo "Host OS: $HOST_OS"
    echo "LLVM Source Ref: $LLVM_REF"
    echo "LLVM Source Revision: $LLVM_SOURCE_REVISION"
    echo ""

    # Create build and install directories
    local build_dir="$BUILD_DIR_BASE/$target"
    local install_dir="$PWD/install/$target"

    mkdir -p "$build_dir"
    mkdir -p "$install_dir"

    # Set up build environment
    setup_build_env "$target"

    # Prepare CMake arguments without flattening values through shell word
    # splitting (SDK paths may contain spaces).
    local cmake_args=()
    while IFS= read -r arg; do
        cmake_args+=("$arg")
    done < <({
        get_base_cmake_args
        get_platform_cmake_args "$target"
        echo "-DCMAKE_INSTALL_PREFIX=$install_dir"
    })

    echo "CMake configuration:"
    printf '  %s\n' "${cmake_args[@]}"
    echo ""

    # Configure
    echo "Configuring build for $target..."
    cd "$build_dir"
    cmake "$LLVM_PROJECTDIR/llvm" "${cmake_args[@]}"

    # Build
    echo "Building $target..."
    local cores
    cores="$(get_cpu_cores)"
    echo "Using $cores CPU cores for build"

    # Build only essential tools to significantly reduce build time
    # LLGo currently only requires libLLVM.dylib for dynamic libraries, and this dylib will be built with the following targets
    ninja -j"$cores" clang llvm-config llvm-ar llvm-nm llc opt lld

    # Install
    echo "Installing $target..."
    ninja install

    # Return to original directory
    cd - > /dev/null

    # Create release directory structure
    create_release_structure "$target" "$install_dir"

    echo ""
    echo "Build completed successfully for $target!"
    echo "Release directory: dist/${target}/esp-clang"
    echo "Install directory: $install_dir"
    echo "Tarball: dist/clang-esp-${VERSION_STRING}-${target}.tar.xz"
}

# Main script logic
main() {
    if [[ $# -ne 1 ]]; then
        show_usage
        exit 1
    fi

    local target="$1"

    # Validate target
    local target_valid=0
    for valid_target in $VALID_TARGETS; do
        if [[ "$target" == "$valid_target" ]]; then
            target_valid=1
            break
        fi
    done

    if [[ $target_valid -eq 0 ]]; then
        echo "Error: Invalid target '$target'"
        echo ""
        show_usage
        exit 1
    fi

    # Check for required tools
    if ! command -v cmake >/dev/null 2>&1; then
        echo "Error: cmake is required but not installed"
        exit 1
    fi

    if ! command -v ninja >/dev/null 2>&1; then
        echo "Error: ninja is required but not installed"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required but not installed"
        exit 1
    fi

    # Download LLVM source
    download_llvm_source

    # Build the platform
    build_platform "$target"
}

# Run main function when executed, while allowing validation helpers to be
# sourced by local tests and CI diagnostics.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
