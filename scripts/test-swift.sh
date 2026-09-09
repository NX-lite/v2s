#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export SWIFTPM_CONFIG_DIR="$repo_root/.build/swiftpm-config"
export SWIFTPM_CACHE_DIR="$repo_root/.build/swiftpm-cache"
export SWIFTPM_SECURITY_DIR="$repo_root/.build/swiftpm-security"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_CONFIG_DIR" "$SWIFTPM_CACHE_DIR" "$SWIFTPM_SECURITY_DIR"

swiftpm_local_cache_args=(
    --scratch-path "$repo_root/.build"
    --cache-path "$SWIFTPM_CACHE_DIR"
    --config-path "$SWIFTPM_CONFIG_DIR"
    --security-path "$SWIFTPM_SECURITY_DIR"
    --manifest-cache local
)

if xcodebuild -version >/dev/null 2>&1; then
    exec swift test "${swiftpm_local_cache_args[@]}" "$@"
fi

clt_root="/Library/Developer/CommandLineTools"
target_sdk="$(xcrun --sdk macosx --show-sdk-path)"
manifest_sdk="$target_sdk"
sdk_cache_key="$(xcrun --sdk macosx --show-sdk-version)"
sdk_cache_key="${sdk_cache_key//./_}"
frameworks_dir="$clt_root/Library/Developer/Frameworks"
developer_lib_dir="$clt_root/Library/Developer/usr/lib"

export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clt-module-cache-$sdk_cache_key"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
clt_cache_dir="$repo_root/.build/clt-cache-$sdk_cache_key"
clt_config_dir="$repo_root/.build/clt-config-$sdk_cache_key"
clt_security_dir="$repo_root/.build/clt-security-$sdk_cache_key"
clt_scratch_dir="$repo_root/.build/clt-scratch-$sdk_cache_key"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$clt_cache_dir" "$clt_config_dir" "$clt_security_dir" "$clt_scratch_dir"

clt_swiftpm_local_cache_args=(
    --scratch-path "$clt_scratch_dir"
    --cache-path "$clt_cache_dir"
    --config-path "$clt_config_dir"
    --security-path "$clt_security_dir"
    --manifest-cache local
)

for required_path in \
    "$manifest_sdk" \
    "$target_sdk" \
    "$frameworks_dir/Testing.framework/Testing" \
    "$developer_lib_dir/lib_TestingInterop.dylib" \
    "/usr/lib/swift"; do
    if [[ ! -e "$required_path" ]]; then
        echo "error: Command Line Tools Swift Testing compatibility requires: $required_path" >&2
        echo "Select a full Xcode toolchain or install matching Command Line Tools." >&2
        exit 1
    fi
done

echo "Using Command Line Tools Swift Testing compatibility path." >&2
SDKROOT="$manifest_sdk" exec swift test \
    "${clt_swiftpm_local_cache_args[@]}" \
    --disable-sandbox \
    --sdk "$target_sdk" \
    -Xswiftc -I -Xswiftc /usr/lib/swift \
    -Xswiftc -F -Xswiftc "$frameworks_dir" \
    -Xlinker -rpath -Xlinker "$frameworks_dir" \
    -Xlinker -rpath -Xlinker "$developer_lib_dir" \
    "$@"
