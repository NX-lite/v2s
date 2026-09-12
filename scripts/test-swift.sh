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

sdk_requires_unavailable_state_macro() {
    local sdk="$1"
    local swiftui_modules="$sdk/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule"
    [[ -d "$swiftui_modules" ]] && grep -Rqs --include='*.swiftinterface' 'type: "StateMacro"' "$swiftui_modules"
}

swiftui_macros_plugin="$clt_root/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
if [[ ! -e "$swiftui_macros_plugin" ]] && sdk_requires_unavailable_state_macro "$target_sdk"; then
    compatible_sdk=""
    for candidate_sdk in "$clt_root"/SDKs/MacOSX[0-9]*.sdk; do
        if [[ -d "$candidate_sdk" ]] && ! sdk_requires_unavailable_state_macro "$candidate_sdk"; then
            compatible_sdk="$candidate_sdk"
            break
        fi
    done
    if [[ -z "$compatible_sdk" ]]; then
        echo "error: Command Line Tools has no SDK compatible with its missing SwiftUIMacros plugin." >&2
        echo "Select a full Xcode toolchain or install matching Command Line Tools." >&2
        exit 1
    fi
    target_sdk="$compatible_sdk"
fi

manifest_sdk="$target_sdk"
sdk_cache_key="$(basename "$target_sdk" .sdk)"
sdk_cache_key="${sdk_cache_key//./_}"
frameworks_dir="$clt_root/Library/Developer/Frameworks"
developer_lib_dir="$clt_root/Library/Developer/usr/lib"
testing_macros_plugin="$clt_root/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clt-module-cache-$sdk_cache_key"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
clt_cache_dir="$repo_root/.build/clt-cache-$sdk_cache_key"
clt_config_dir="$repo_root/.build/clt-config-$sdk_cache_key"
clt_security_dir="$repo_root/.build/clt-security-$sdk_cache_key"
task_tmp_root="${TMPDIR:-/private/tmp}"
repo_cache_key="$(printf '%s' "$repo_root" | cksum)"
repo_cache_key="${repo_cache_key%% *}"
clt_scratch_dir="${task_tmp_root%/}/v2s-swiftpm-$repo_cache_key-$sdk_cache_key"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$clt_cache_dir" "$clt_config_dir" "$clt_security_dir" "$clt_scratch_dir"

# Do not preserve Finder metadata when SwiftPM copies package artifacts.
export COPYFILE_DISABLE=1

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
    "$testing_macros_plugin" \
    "/usr/lib/swift"; do
    if [[ ! -e "$required_path" ]]; then
        echo "error: Command Line Tools Swift Testing compatibility requires: $required_path" >&2
        echo "Select a full Xcode toolchain or install matching Command Line Tools." >&2
        exit 1
    fi
done

echo "Using Command Line Tools Swift Testing compatibility path." >&2
export V2S_CLT_TESTING=1
SDKROOT="$manifest_sdk" exec swift test \
    "${clt_swiftpm_local_cache_args[@]}" \
    --disable-sandbox \
    --sdk "$target_sdk" \
    -Xswiftc -I -Xswiftc /usr/lib/swift \
    -Xswiftc -F -Xswiftc "$frameworks_dir" \
    -Xswiftc -load-plugin-library -Xswiftc "$testing_macros_plugin" \
    -Xlinker -rpath -Xlinker "$frameworks_dir" \
    -Xlinker -rpath -Xlinker "$developer_lib_dir" \
    "$@"
