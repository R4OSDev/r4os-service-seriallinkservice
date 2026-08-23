#!/bin/sh
set -eu

module_root=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
settings_file="$module_root/Settings.R4S"

if [ ! -f "$settings_file" ]; then
    echo "ERROR: Settings file not found: $settings_file" >&2
    exit 1
fi

artifacts_setting=
contract_setting=
devkit_setting=
libraries_setting=
sdk_setting=
zig_setting=

while IFS='=' read -r key value; do
    case "$key" in
        ARTIFACTS_ROOT) artifacts_setting=$value ;;
        CONTRACT_ROOT) contract_setting=$value ;;
        DEVKIT_ROOT) devkit_setting=$value ;;
        LIBRARIES_ROOT) libraries_setting=$value ;;
        SDK_ROOT) sdk_setting=$value ;;
        ZIG_ROOT) zig_setting=$value ;;
    esac
done < "$settings_file"

require_setting() {
    if [ -z "$2" ]; then
        echo "ERROR: $1 is missing in $settings_file" >&2
        exit 1
    fi
}

resolve_path() {
    case "$2" in
        /*) printf '%s\n' "$2" ;;
        *) printf '%s/%s\n' "$1" "$2" ;;
    esac
}

require_setting ARTIFACTS_ROOT "$artifacts_setting"
require_setting CONTRACT_ROOT "$contract_setting"
require_setting DEVKIT_ROOT "$devkit_setting"
require_setting SDK_ROOT "$sdk_setting"
require_setting ZIG_ROOT "$zig_setting"

artifacts_root=$(resolve_path "$module_root" "$artifacts_setting")
contract_root=$(resolve_path "$module_root" "$contract_setting")
devkit_root=$(resolve_path "$module_root" "$devkit_setting")
sdk_root=$(resolve_path "$module_root" "$sdk_setting")
zig_root=$(resolve_path "$devkit_root" "$zig_setting")

if [ ! -f "$contract_root/build.zig.zon" ]; then
    echo "ERROR: Contract repository not found: $contract_root" >&2
    exit 1
fi
if [ ! -f "$sdk_root/build.zig.zon" ]; then
    echo "ERROR: SDK repository not found: $sdk_root" >&2
    exit 1
fi

libraries_root=
if [ -n "$libraries_setting" ]; then
    libraries_root=$(resolve_path "$module_root" "$libraries_setting")
    if [ ! -f "$libraries_root/build.zig.zon" ]; then
        echo "ERROR: Libraries repository not found: $libraries_root" >&2
        exit 1
    fi
fi

zig_exe=$zig_root/zig
if [ ! -x "$zig_exe" ]; then
    echo "ERROR: Zig executable not found: $zig_exe" >&2
    exit 1
fi

mkdir -p "$artifacts_root"
cd "$module_root"
if [ -n "$libraries_root" ]; then
    exec "$zig_exe" build --prefix "$artifacts_root" "--fork=$sdk_root" "--fork=$contract_root" "--fork=$libraries_root" "$@"
fi
exec "$zig_exe" build --prefix "$artifacts_root" "--fork=$sdk_root" "--fork=$contract_root" "$@"
