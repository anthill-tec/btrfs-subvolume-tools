#!/bin/bash
# Pattern matching library for btrfs-subvolume-tools
# Version: 1.0.0
# Description: Provides optimized pattern matching functionality with memory management

# Prevent multiple inclusion
if [[ -n "$_PATTERN_MATCHER_LOADED" ]]; then
    return 0
fi
_PATTERN_MATCHER_LOADED=1

# Debug helper
_pattern_debug() {
    if [[ -n "$DEBUG" ]]; then
        echo "[PATTERN DEBUG] $*" >&2
    fi
}

# ===== Pattern Classification Functions =====

# Classify a pattern by its type
# Returns: pattern type as string
pattern_classify() {
    local pattern="$1"
    
    if [[ "$pattern" == */ ]]; then
        echo "directory_with_trailing_slash"
    elif [[ "$pattern" == */* && "$pattern" != *"*"* ]]; then
        echo "exact_path"
    elif [[ "$pattern" == **/* ]]; then
        echo "double_asterisk"
    elif [[ "$pattern" == *.*  && "$pattern" != */* ]]; then
        echo "file_extension"
    else
        echo "regular"
    fi
}

# Get the specificity rank of a pattern type
# Higher rank = more specific pattern
# Returns: numeric rank
pattern_get_rank() {
    local pattern_type="$1"
    
    case "$pattern_type" in
        "exact_path") echo "10" ;;
        "directory_with_trailing_slash") echo "8" ;;
        "double_asterisk") echo "6" ;;
        "file_extension") echo "4" ;;
        "regular") echo "2" ;;
        *) echo "1" ;;
    esac
}

# Determine if a new pattern should override an existing one
# Returns: 0 (true) if should override, 1 (false) otherwise
pattern_should_override() {
    local existing_rank="$1"
    local new_rank="$2"
    
    if [[ $new_rank -gt $existing_rank ]]; then
        return 0
    else
        return 1
    fi
}

# ===== Core API Functions =====

# Initialize pattern matching system
# Usage: pattern_init
pattern_init() {
    # Global associative arrays for pattern metadata
    declare -g -A _PATTERN_TYPES
    declare -g -A _PATTERN_RANKS
    
    # Global associative arrays for pattern-specific matches
    declare -g -A _PATTERN_FILES
    declare -g -A _PATTERN_DIRS
    
    # Global associative arrays for path metadata
    declare -g -A _PATH_PATTERNS
    declare -g -A _PATH_RANKS
    
    # Global arrays for compatibility with existing code
    declare -g -a _EXCLUDED_FILES
    declare -g -a _EXCLUDED_DIRS
    
    # Track initialization
    _PATTERN_MATCHER_INITIALIZED=1
    
    _pattern_debug "Pattern matcher initialized"
}

# Add a pattern to be matched
# Usage: pattern_add "pattern"
pattern_add() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        pattern_init
    fi
    
    local pattern="$1"
    local type
    local rank
    
    # Skip empty patterns
    if [[ -z "$pattern" ]]; then
        return
    fi
    
    # Classify and rank the pattern
    type=$(pattern_classify "$pattern")
    rank=$(pattern_get_rank "$type")
    
    # Store pattern metadata
    _PATTERN_TYPES["$pattern"]="$type"
    _PATTERN_RANKS["$pattern"]="$rank"
    
    # Initialize empty arrays for this pattern's matches
    _PATTERN_FILES["$pattern"]=""
    _PATTERN_DIRS["$pattern"]=""
    
    _pattern_debug "Added pattern: $pattern (type: $type, rank: $rank)"
}

# Match files against patterns
# Usage: pattern_match_files "source_dir"
pattern_match_files() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        pattern_init
    fi
    
    local source_dir="$1"
    local pattern
    
    # Normalize source path
    source_dir="${source_dir%/}"
    
    _pattern_debug "Matching patterns in directory: $source_dir"
    
    # Process each pattern
    for pattern in "${!_PATTERN_TYPES[@]}"; do
        local pattern_type="${_PATTERN_TYPES["$pattern"]}"
        local pattern_rank="${_PATTERN_RANKS["$pattern"]}"
        local find_args=()
        local results=()
        
        _pattern_debug "Processing pattern: $pattern (type: $pattern_type)"
        
        # Build find command based on pattern type
        case "$pattern_type" in
            "exact_path")
                # Exact path - just check if it exists
                if [[ -e "$source_dir/$pattern" ]]; then
                    results=("$source_dir/$pattern")
                fi
                ;;
                
            "directory_with_trailing_slash")
                # Directory with trailing slash - match the directory
                local dir_pattern="${pattern%/}"
                find_args=(-type d -path "*/$dir_pattern" -o -path "*/$dir_pattern/*")
                ;;
                
            "double_asterisk")
                # Double-asterisk pattern - matches any level of directories
                local dir_name="${pattern#**/}"
                find_args=(-path "*/$dir_name" -o -name "$dir_name")
                ;;
                
            "file_extension")
                # File extension pattern - match by extension
                find_args=(-name "$pattern")
                ;;
                
            *)
                # Regular pattern - standard glob
                find_args=(-name "$pattern")
                ;;
        esac
        
        # If we need to run find
        if [[ ${#find_args[@]} -gt 0 ]]; then
            # Run find and capture results
            while IFS= read -r -d '' item; do
                results+=("$item")
            done < <(find "$source_dir" "${find_args[@]}" -print0 2>/dev/null)
        fi
        
        _pattern_debug "Found ${#results[@]} matches for pattern: $pattern"
        
        # Process results
        for item in "${results[@]}"; do
            # Skip if item doesn't exist (might have been removed)
            if [[ ! -e "$item" ]]; then
                continue
            fi
            
            # Determine if file or directory
            if [[ -d "$item" ]]; then
                # Process directory
                _pattern_add_dir "$item" "$pattern" "$pattern_rank"
            else
                # Process file
                _pattern_add_file "$item" "$pattern" "$pattern_rank"
            fi
        done
    done
    
    # Build compatibility arrays
    _build_compatibility_arrays
    
    _pattern_debug "Pattern matching completed"
}

# Add a file to the excluded files list
# Internal function
_pattern_add_file() {
    local file="$1"
    local pattern="$2"
    local pattern_rank="$3"
    local current_pattern
    local current_rank
    
    # Check if this file is already matched by a pattern
    current_pattern="${_PATH_PATTERNS["$file"]}"
    
    if [[ -n "$current_pattern" ]]; then
        # File already matched, check if we should override
        current_rank="${_PATH_RANKS["$file"]}"
        
        if pattern_should_override "$current_rank" "$pattern_rank"; then
            # New pattern is more specific, override
            _PATH_PATTERNS["$file"]="$pattern"
            _PATH_RANKS["$file"]="$pattern_rank"
            
            # Update pattern-specific arrays
            _pattern_debug "Pattern override for file: $file ($current_pattern -> $pattern)"
        else
            # Existing pattern is more specific, keep it
            return
        fi
    else
        # New file, add it
        _PATH_PATTERNS["$file"]="$pattern"
        _PATH_RANKS["$file"]="$pattern_rank"
    fi
    
    # Add to pattern-specific array
    # Append to space-separated list
    _PATTERN_FILES["$pattern"]="${_PATTERN_FILES["$pattern"]} $file"
}

# Add a directory to the excluded directories list
# Internal function
_pattern_add_dir() {
    local dir="$1"
    local pattern="$2"
    local pattern_rank="$3"
    local current_pattern
    local current_rank
    
    # Check if this directory is already matched by a pattern
    current_pattern="${_PATH_PATTERNS["$dir"]}"
    
    if [[ -n "$current_pattern" ]]; then
        # Directory already matched, check if we should override
        current_rank="${_PATH_RANKS["$dir"]}"
        
        if pattern_should_override "$current_rank" "$pattern_rank"; then
            # New pattern is more specific, override
            _PATH_PATTERNS["$dir"]="$pattern"
            _PATH_RANKS["$dir"]="$pattern_rank"
            
            # Update pattern-specific arrays
            _pattern_debug "Pattern override for directory: $dir ($current_pattern -> $pattern)"
        else
            # Existing pattern is more specific, keep it
            return
        fi
    else
        # New directory, add it
        _PATH_PATTERNS["$dir"]="$pattern"
        _PATH_RANKS["$dir"]="$pattern_rank"
    fi
    
    # Add to pattern-specific array
    # Append to space-separated list
    _PATTERN_DIRS["$pattern"]="${_PATTERN_DIRS["$pattern"]} $dir"
}

# Build compatibility arrays for existing code
# Internal function
_build_compatibility_arrays() {
    # Clear existing arrays
    _EXCLUDED_FILES=()
    _EXCLUDED_DIRS=()
    
    # Add all files
    for file in "${!_PATH_PATTERNS[@]}"; do
        if [[ -f "$file" ]]; then
            _EXCLUDED_FILES+=("$file")
        elif [[ -d "$file" ]]; then
            _EXCLUDED_DIRS+=("$file")
        fi
    done
    
    _pattern_debug "Built compatibility arrays: ${#_EXCLUDED_FILES[@]} files, ${#_EXCLUDED_DIRS[@]} directories"
}

# Get all excluded files
# Usage: pattern_get_excluded_files
pattern_get_excluded_files() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        echo ""
        return
    fi
    
    # Print all excluded files
    for file in "${_EXCLUDED_FILES[@]}"; do
        echo "$file"
    done
}

# Get all excluded directories
# Usage: pattern_get_excluded_dirs
pattern_get_excluded_dirs() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        echo ""
        return
    fi
    
    # Print all excluded directories
    for dir in "${_EXCLUDED_DIRS[@]}"; do
        echo "$dir"
    done
}

# Get files excluded by a specific pattern
# Usage: pattern_get_files_by_pattern "pattern"
pattern_get_files_by_pattern() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        echo ""
        return
    fi
    
    local pattern="$1"
    local files="${_PATTERN_FILES["$pattern"]}"
    
    # Return space-separated list
    if [[ -n "$files" ]]; then
        echo "$files"
    fi
}

# Get directories excluded by a specific pattern
# Usage: pattern_get_dirs_by_pattern "pattern"
pattern_get_dirs_by_pattern() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        echo ""
        return
    fi
    
    local pattern="$1"
    local dirs="${_PATTERN_DIRS["$pattern"]}"
    
    # Return space-separated list
    if [[ -n "$dirs" ]]; then
        echo "$dirs"
    fi
}

# Create a progress indicator function for searches
show_progress() {
    local pid=$1
    local spin='-\|/'
    local i=0
    echo -n "  Searching... "
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  Searching... %c " "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r  Search completed!      \n"
}

# Process a pattern and add matching files/directories to the exclusion lists
# Usage: _process_pattern <source_dir> <pattern>
_process_pattern() {
    local source_dir="$1"
    local pattern="$2"
    
    # Skip empty patterns
    if [[ -z "$pattern" ]]; then
        return
    fi
    
    # Get the pattern type
    local pattern_type=$(pattern_classify "$pattern")
    local pattern_rank=$(pattern_get_rank "$pattern_type")
    
    # Add the pattern to the list
    _pattern_debug "Added pattern: $pattern (type: $pattern_type, rank: $pattern_rank)"
    
    # Process the pattern based on its type
    if [[ "$pattern" == */* && "$pattern" != *"*"* ]]; then
        # Exact path pattern
        echo "  Exact path pattern: '$pattern'"
        
        # Check if the file exists
        if [[ -f "$source_dir/$pattern" ]]; then
            # Add to excluded files
            EXCLUDED_FILES+=("$source_dir/$pattern")
            PATTERN_FILES["$pattern"]+=" $source_dir/$pattern"
            
            # Add to EXCLUDED_PATTERN_MATCHES for copy_data
            EXCLUDED_PATTERN_MATCHES+=("-not" "-path" "$source_dir/$pattern")
        elif [[ -d "$source_dir/$pattern" ]]; then
            # Add to excluded directories
            EXCLUDED_DIRS+=("$source_dir/$pattern")
            PATTERN_DIRS["$pattern"]+=" $source_dir/$pattern"
            
            # Also find and exclude all files within this directory
            while IFS= read -r file; do
                EXCLUDED_FILES+=("$file")
                PATTERN_FILES["$pattern"]+=" $file"
            done < <(find "$source_dir/$pattern" -type f 2>/dev/null)
            
            # Add to EXCLUDED_PATTERN_MATCHES for copy_data
            EXCLUDED_PATTERN_MATCHES+=("-not" "-path" "$source_dir/$pattern" "-not" "-path" "$source_dir/$pattern/*")
        fi
    elif [[ "$pattern" == */ ]]; then
        # Directory pattern with trailing slash
        # Remove the trailing slash
        dir_pattern="${pattern%/}"
        echo "  Directory pattern with trailing slash: '$dir_pattern/'"
        
        # Check if the directory exists
        if [[ -d "$source_dir/$dir_pattern" ]]; then
            # Add to excluded directories (without trailing slash)
            EXCLUDED_DIRS+=("$source_dir/$dir_pattern")
            PATTERN_DIRS["$pattern"]+=" $source_dir/$dir_pattern"
            
            # Also find and exclude all files within this directory
            while IFS= read -r file; do
                EXCLUDED_FILES+=("$file")
                PATTERN_FILES["$pattern"]+=" $file"
            done < <(find "$source_dir/$dir_pattern" -type f 2>/dev/null)
            
            # Add to EXCLUDED_PATTERN_MATCHES for copy_data
            EXCLUDED_PATTERN_MATCHES+=("-not" "-path" "$source_dir/$dir_pattern" "-not" "-path" "$source_dir/$dir_pattern/*")
        fi
    elif [[ "$pattern" == *.* && "$pattern" != */* ]]; then
        # File extension pattern
        echo "  File extension pattern: '$pattern'"
        
        # Extract the extension
        local extension="${pattern#*.}"
        
        # Find all files with that extension
        local temp_file=$(mktemp)
        (find "$source_dir" -type f -name "*.$extension" 2>/dev/null > "$temp_file") &
        local find_pid=$!
        show_progress $find_pid
        wait $find_pid
        
        # Process the results
        while IFS= read -r file; do
            EXCLUDED_FILES+=("$file")
            PATTERN_FILES["$pattern"]+=" $file"
        done < "$temp_file"
        
        # Clean up
        rm -f "$temp_file"
        
        # Add to EXCLUDED_PATTERN_MATCHES for copy_data
        EXCLUDED_PATTERN_MATCHES+=("-not" "-name" "*.$extension")
    elif [[ "$pattern" == **/* ]]; then
        # Double-asterisk pattern
        echo "  Double-asterisk pattern: '$pattern'"
        
        # Extract the pattern after the double asterisk
        local path_pattern="${pattern#**/}"
        
        # Find all directories matching the pattern
        local temp_file=$(mktemp)
        (find "$source_dir" -type d -path "*/$path_pattern*" 2>/dev/null > "$temp_file") &
        local find_pid=$!
        show_progress $find_pid
        wait $find_pid
        
        # Process the directory results
        while IFS= read -r dir; do
            EXCLUDED_DIRS+=("$dir")
            PATTERN_DIRS["$pattern"]+=" $dir"
            
            # Also find and exclude all files within these directories
            local temp_file2=$(mktemp)
            find "$dir" -type f 2>/dev/null > "$temp_file2"
            
            while IFS= read -r file; do
                EXCLUDED_FILES+=("$file")
                PATTERN_FILES["$pattern"]+=" $file"
            done < "$temp_file2"
            
            rm -f "$temp_file2"
        done < "$temp_file"
        
        # Clean up
        rm -f "$temp_file"
        
        # Add to EXCLUDED_PATTERN_MATCHES for copy_data
        EXCLUDED_PATTERN_MATCHES+=("-not" "-path" "*/$path_pattern*" "-not" "-path" "*/$path_pattern*/*")
    else
        # Regular pattern
        echo "  Regular pattern: '$pattern'"
        
        # Check if it's a directory name pattern
        if [[ -d "$source_dir/$pattern" ]]; then
            echo "  Directory name pattern: '$pattern'"
            
            # Add the directory to the excluded directories list
            EXCLUDED_DIRS+=("$source_dir/$pattern")
            PATTERN_DIRS["$pattern"]+=" $source_dir/$pattern"
            
            # Also find and exclude all files within this directory
            while IFS= read -r file; do
                EXCLUDED_FILES+=("$file")
                PATTERN_FILES["$pattern"]+=" $file"
            done < <(find "$source_dir/$pattern" -type f 2>/dev/null)
            
            # Add to EXCLUDED_PATTERN_MATCHES for copy_data
            EXCLUDED_PATTERN_MATCHES+=("-not" "-path" "$source_dir/$pattern" "-not" "-path" "$source_dir/$pattern/*")
        fi
        
        # Find all matching files
        (find "$source_dir" -type f -name "*$pattern*" 2>/dev/null) &
        local find_pid=$!
        show_progress $find_pid
        wait $find_pid
        
        # Process the results
        while IFS= read -r file; do
            EXCLUDED_FILES+=("$file")
            PATTERN_FILES["$pattern"]+=" $file"
        done < <(find "$source_dir" -type f -name "*$pattern*" 2>/dev/null)
        
        # Add to EXCLUDED_PATTERN_MATCHES for copy_data
        EXCLUDED_PATTERN_MATCHES+=("-not" "-name" "*$pattern*")
    fi
}

# Generate a list of files and directories that match exclude patterns
# This function is the main entry point for pattern matching
# Usage: generate_exclude_matches "source_dir" "EXCLUDE_PATTERNS[@]"
generate_exclude_matches() {
    local source_dir="$1"
    local -n patterns="$2"
    
    # Initialize arrays
    EXCLUDED_FILES=()
    EXCLUDED_DIRS=()
    EXCLUDED_PATTERN_MATCHES=()
    declare -A PATTERN_FILES
    declare -A PATTERN_DIRS
    
    # Initialize the pattern matcher
    pattern_init
    
    # If no patterns, return
    if [[ ${#patterns[@]} -eq 0 ]]; then
        echo "No exclude patterns provided"
        return 0
    fi
    
    # Process each pattern
    local pattern_count=${#patterns[@]}
    local pattern_index=1
    
    for pattern in "${patterns[@]}"; do
        # Trim any whitespace
        pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Skip empty patterns and comments
        if [[ -z "$pattern" || "$pattern" == \#* ]]; then
            continue
        fi
        
        # Add pattern to matcher
        pattern_add "$pattern"
        
        echo "Processing pattern ($pattern_index/$pattern_count): $pattern"
        _process_pattern "$source_dir" "$pattern"
        pattern_index=$((pattern_index + 1))
    done
    
    # Build the FIND_EXCLUDE_OPTS string from the pattern matches
    FIND_EXCLUDE_OPTS=""
    for pattern_match in "${EXCLUDED_PATTERN_MATCHES[@]}"; do
        FIND_EXCLUDE_OPTS+=" $pattern_match"
    done
    
    # Print summary
    echo "Exclude pattern analysis complete:"
    echo "  - ${#EXCLUDED_FILES[@]} files excluded"
    echo "  - ${#EXCLUDED_DIRS[@]} directories excluded"
    
    return 0
}

# Clean up resources
# Usage: pattern_cleanup
pattern_cleanup() {
    # Ensure initialized
    if [[ -z "$_PATTERN_MATCHER_INITIALIZED" ]]; then
        return
    fi
    
    # Unset all global variables
    unset _PATTERN_TYPES
    unset _PATTERN_RANKS
    unset _PATTERN_FILES
    unset _PATTERN_DIRS
    unset _PATH_PATTERNS
    unset _PATH_RANKS
    unset _EXCLUDED_FILES
    unset _EXCLUDED_DIRS
    
    # Mark as uninitialized
    unset _PATTERN_MATCHER_INITIALIZED
    
    _pattern_debug "Pattern matcher cleaned up"
}

# Set up cleanup on exit
trap pattern_cleanup EXIT

# Export functions
declare -fx pattern_classify
declare -fx pattern_get_rank
declare -fx pattern_should_override
declare -fx pattern_init
declare -fx pattern_add
declare -fx pattern_match_files
declare -fx pattern_get_excluded_files
declare -fx pattern_get_excluded_dirs
declare -fx pattern_get_files_by_pattern
declare -fx pattern_get_dirs_by_pattern
declare -fx pattern_cleanup
declare -fx generate_exclude_matches

# Initialize by default
pattern_init
