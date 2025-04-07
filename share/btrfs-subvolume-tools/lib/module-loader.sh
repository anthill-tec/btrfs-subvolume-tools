#!/bin/bash
# Module loader for btrfs-subvolume-tools
# Version: 1.0.0
# Description: Provides module loading functionality following Linux conventions

# Prevent multiple inclusion
if [[ -n "$_MODULE_LOADER_LOADED" ]]; then
    return 0
fi
_MODULE_LOADER_LOADED=1

# Debug helper
_module_debug() {
    if [[ -n "$DEBUG" ]]; then
        echo "[MODULE DEBUG] $*" >&2
    fi
}

# Find a module in standard locations
# Usage: find_module "module_name"
# Returns: Full path to module or empty string if not found
find_module() {
    local module_name="$1"
    local module_paths=(
        # Try relative path first (development environment)
        "$(dirname "$0")/../share/btrfs-subvolume-tools/lib/${module_name}.sh"
        # Standard system locations
        "/usr/share/btrfs-subvolume-tools/lib/${module_name}.sh"
        "/usr/local/share/btrfs-subvolume-tools/lib/${module_name}.sh"
    )
    
    for path in "${module_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Load a module safely
# Usage: load_module "module_name"
# Returns: 0 if module loaded, 1 if not found
load_module() {
    local module_name="$1"
    local module_path
    
    module_path=$(find_module "$module_name")
    if [[ $? -eq 0 ]]; then
        # shellcheck disable=SC1090
        source "$module_path"
        _module_debug "Loaded module: $module_name from $module_path"
        return 0
    else
        echo "Warning: Could not find module '$module_name'" >&2
        return 1
    fi
}

# Export functions
declare -fx find_module
declare -fx load_module
