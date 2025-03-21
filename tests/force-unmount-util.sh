#!/bin/bash
# Force unmount utility for BTRFS subvolumes during testing
# This addresses the issue with persistent "device busy" errors

# Force unmount a directory and all of its submounts
# Works recursively to ensure proper unmounting
force_unmount_path() {
    local path="$1"
    local verbose="${2:-false}"
    local retries="${3:-3}"
    local delay="${4:-2}"
    
    # Check if path exists
    if [ ! -d "$path" ]; then
        [ "$verbose" = "true" ] && echo "Path does not exist: $path"
        return 0
    fi
    
    # Check if path is mounted
    if ! mountpoint -q "$path" && ! mount | grep -q " $path "; then
        [ "$verbose" = "true" ] && echo "Path is not a mountpoint: $path"
        return 0
    fi
    
    # Find submounts in reverse order (deepest first)
    local submounts=()
    while read -r mount_point; do
        submounts+=("$mount_point")
    done < <(mount | grep "$path" | awk '{print $3}' | sort -r)
    
    if [ ${#submounts[@]} -eq 0 ]; then
        [ "$verbose" = "true" ] && echo "No mounts found for $path"
        return 0
    fi
    
    [ "$verbose" = "true" ] && echo "Found ${#submounts[@]} mounts to unmount"
    
    # Kill processes using the mounts
    for mount_point in "${submounts[@]}"; do
        if [ "$verbose" = "true" ]; then
            echo "Checking for processes using $mount_point"
            fuser -vm "$mount_point" 2>&1 || true
        fi
        
        fuser -km "$mount_point" 2>/dev/null || true
    done
    
    # Force sync
    sync
    
    # Try unmounting each submount with retries
    for mount_point in "${submounts[@]}"; do
        local attempt=1
        local success=false
        
        while [ $attempt -le $retries ] && [ "$success" = "false" ]; do
            [ "$verbose" = "true" ] && echo "Unmounting $mount_point (attempt $attempt/$retries)"
            
            # Try different unmount strategies
            if umount "$mount_point" 2>/dev/null; then
                success=true
                [ "$verbose" = "true" ] && echo "Successfully unmounted $mount_point"
            elif [ $attempt -eq 2 ]; then
                [ "$verbose" = "true" ] && echo "Trying lazy unmount for $mount_point"
                umount -l "$mount_point" 2>/dev/null && success=true
            elif [ $attempt -eq 3 ]; then
                [ "$verbose" = "true" ] && echo "Trying forced unmount for $mount_point"
                umount -f "$mount_point" 2>/dev/null && success=true
                
                if [ "$success" = "false" ]; then
                    [ "$verbose" = "true" ] && echo "Trying to terminate all processes using $mount_point"
                    fuser -km "$mount_point" 2>/dev/null || true
                    sync
                    umount -f "$mount_point" 2>/dev/null && success=true
                fi
            fi
            
            if [ "$success" = "false" ]; then
                [ "$verbose" = "true" ] && echo "Unmount attempt $attempt failed for $mount_point"
                ((attempt++))
                [ $attempt -le $retries ] && sleep $delay
            fi
        done
        
        if [ "$success" = "false" ] && [ "$verbose" = "true" ]; then
            echo "Failed to unmount $mount_point after $retries attempts"
            echo "Processes using the mount:"
            fuser -vm "$mount_point" 2>&1 || true
        fi
    done
    
    # Check if all mounts were successfully unmounted
    if mountpoint -q "$path" || mount | grep -q " $path "; then
        [ "$verbose" = "true" ] && echo "Warning: Some mounts under $path could not be unmounted"
        return 1
    else
        [ "$verbose" = "true" ] && echo "All mounts under $path successfully unmounted"
        return 0
    fi
}

# Unmount all BTRFS subvolumes under a path
unmount_btrfs_subvolumes() {
    local base_path="$1"
    local verbose="${2:-false}"
    
    # Find and unmount BTRFS subvolumes
    local subvolumes=()
    if command -v btrfs >/dev/null 2>&1; then
        while read -r subvol_path; do
            if [ -n "$subvol_path" ] && [ -d "$base_path/$subvol_path" ]; then
                subvolumes+=("$base_path/$subvol_path")
            fi
        done < <(btrfs subvolume list "$base_path" 2>/dev/null | awk '{print $NF}')
    fi
    
    # Add the base path itself
    subvolumes+=("$base_path")
    
    # Unmount all found subvolumes
    for subvol in "${subvolumes[@]}"; do
        force_unmount_path "$subvol" "$verbose"
    done
}

# Clean up all test mounts
cleanup_test_mounts() {
    local test_path="$1"
    local verbose="${2:-false}"
    
    # Force a global sync
    sync
    
    # Kill any processes that might be using the test directories
    if [ -d "$test_path" ]; then
        fuser -km "$test_path" 2>/dev/null || true
    fi
    
    # Unmount the path and all its submounts
    force_unmount_path "$test_path" "$verbose"
    
    # Additional safety: Try to unmount any remaining mounts with test_path in their name
    local remaining_mounts=$(mount | grep "$test_path" | awk '{print $3}' | sort -r)
    if [ -n "$remaining_mounts" ]; then
        [ "$verbose" = "true" ] && echo "Found remaining mounts to clean up"
        
        while read -r mount_point; do
            [ "$verbose" = "true" ] && echo "Force unmounting $mount_point"
            umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || true
        done <<< "$remaining_mounts"
    fi
    
    return 0
}

# Main function when script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <mount_path> [verbose=true|false]"
        exit 1
    fi
    
    verbose="${2:-true}"
    cleanup_test_mounts "$1" "$verbose"
    exit $?
fi
