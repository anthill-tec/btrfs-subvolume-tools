#!/bin/bash
set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Default values
SOURCE_DIR=""
DESTINATION_DIR=""
BACKUP_METHOD="tar"
ACTUAL_BACKUP_METHOD=""
ERROR_HANDLING="strict"
NON_INTERACTIVE=false
SHOW_EXCLUDED=false
# List to track files that failed to copy
FAILED_FILES=()
# Arrays for exclude patterns
EXCLUDE_PATTERNS=()
EXCLUDE_FILES=()
INTERACTIVE_EXCLUDE_MODE=false
# Global variable for process IDs
CP_PID=""
DEBUG_MODE=false
DEBUG_LOG=""
DIALOG_SHOWN=false

# Debug function to log messages when debug mode is enabled
debug_log() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# More detailed debug function for pattern matching
debug_pattern_log() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "[DEBUG PATTERN] $1" >&2
    fi
}

# Show help message
show_help() {
  echo -e "${BLUE}BTRFS Backup Utility${NC}"
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -h, --help                 Show this help message"
  echo "  -s, --source DIR           Source directory to backup (required)"
  echo "  -d, --destination DIR      Destination directory for backup (required)"
  echo "  -m, --method METHOD        Specify the method for copying data:"
  echo "                             tar: Use tar with pv for compression and progress"
  echo "                                  (requires: tar, pv)"
  echo "                             parallel: Use GNU parallel for multi-threaded copying"
  echo "                                  (requires: parallel)"
  echo "                             (Automatically falls back if dependencies not met)"
  echo "  -e, --error-handling MODE  Specify how to handle file copy errors:"
  echo "                             strict: Stop on first error (default)"
  echo "                             continue: Skip problem files and continue"
  echo "  -n, --non-interactive      Run without prompting for user input"
  echo "  --exclude=PATTERN          Exclude files/directories matching PATTERN"
  echo "                             (can be specified multiple times)"
  echo "  --exclude-from=FILE        Read exclude patterns from FILE (one pattern per line)"
  echo "  --show-excluded            Show interactive UI to review and modify excluded files"
  echo "  --debug                    Enable debug mode with detailed logging"
  echo
  echo "Exclude Pattern Format:"
  echo "  - Simple glob patterns: *.log, tmp/, etc."
  echo "  - Patterns with / are relative to the source root"
  echo "  - Patterns without / match anywhere in the path"
  echo
  echo "Example:"
  echo "  $0 --source /home/user --destination /mnt/backup/home"
  echo "  $0 -s /var -d /mnt/backup/var --method=parallel"
  echo "  $0 -s /home/user -d /mnt/backup/home --error-handling=continue"
  echo "  $0 -s /home/user -d /mnt/backup/home --exclude='*.log' --exclude='tmp/'"
  echo "  $0 -s /home/user -d /mnt/backup/home --exclude-from=exclude_patterns.txt"
  echo "  $0 -s /home/user -d /mnt/backup/home --non-interactive"
  echo "  $0 -s /home/user -d /mnt/backup/home --debug"
  echo
  echo "Automated usage:"
  echo "  For scripts, testing, and automated environments, always use the --non-interactive flag"
  echo "  to prevent the script from waiting for user input. Without this flag, the script may"
  echo "  prompt for confirmation in certain scenarios, causing automation to hang indefinitely."
  echo
}

# Check dependencies and determine actual backup method
determine_actual_backup_method() {
    # Start with the user's choice
    ACTUAL_BACKUP_METHOD="$BACKUP_METHOD"
    
    # Check dependencies and fall back as needed
    case "$ACTUAL_BACKUP_METHOD" in
        tar)
            if ! command -v tar >/dev/null 2>&1 || ! command -v pv >/dev/null 2>&1; then
                echo -e "${YELLOW}Warning: tar or pv not found, falling back to cp with progress${NC}"
                ACTUAL_BACKUP_METHOD="cp-progress"
            fi
            ;;
        parallel)
            if ! command -v parallel >/dev/null 2>&1; then
                echo -e "${YELLOW}Warning: GNU parallel not found, falling back to tar${NC}"
                ACTUAL_BACKUP_METHOD="tar"
                # Recursively check dependencies for tar
                if ! command -v tar >/dev/null 2>&1 || ! command -v pv >/dev/null 2>&1; then
                    echo -e "${YELLOW}Warning: tar or pv not found, falling back to cp with progress${NC}"
                    ACTUAL_BACKUP_METHOD="cp-progress"
                fi
            fi
            ;;
    esac
    
    # Final fallback to plain cp if progress tool isn't available
    if [ "$ACTUAL_BACKUP_METHOD" = "cp-progress" ] && ! command -v progress >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: progress tool not found, using plain cp${NC}"
        ACTUAL_BACKUP_METHOD="cp-plain"
    fi
}

# Helper function for cleanup during cancellation
cleanup_copy() {
    case "$ACTUAL_BACKUP_METHOD" in
        cp-progress)
            # Kill the cp process if it exists
            if [ -n "$CP_PID" ]; then
                kill $CP_PID 2>/dev/null
            fi
            ;;
        parallel)
            # Stop parallel processes
            parallel --halt now,fail=1 ::: "true" 2>/dev/null
            ;;
    esac
}

# Global cleanup function for handling interruptions
global_cleanup() {
    echo -e "${RED}Operation interrupted by user${NC}"
    cleanup_copy
    
    if [ "$NON_INTERACTIVE" != true ]; then
        echo
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r continue_decision
        echo
        
        # Default to "n" if user just presses Enter
        continue_decision=${continue_decision:-n}
        
        if [[ $continue_decision =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Continuing despite interruption...${NC}"
            # Reset the trap and return to continue execution
            trap - INT TERM
            return 0
        fi
    fi
    
    echo -e "${RED}Backup cancelled${NC}"
    exit 1
}

# Generate a list of files and directories that match exclude patterns
# This function extracts the exclusion pattern logic from copy_data
# to ensure consistent exclusion logic across the script
generate_exclude_matches() {
  local source_dir="$1"
  
  # Arrays to store matched files and directories
  EXCLUDED_FILES=()
  EXCLUDED_DIRS=()
  EXCLUDED_PATTERN_MATCHES=()
  
  # Process each pattern using the same logic as in copy_data
  echo -e "${BLUE}Analyzing exclude patterns...${NC}"
  
  # Create a progress indicator function for searches
  show_progress() {
    local pid=$1
    local spin='-\|/'
    local i=0
    echo -n "  ${YELLOW}Searching... ${NC}"
    while kill -0 $pid 2>/dev/null; do
      i=$(( (i+1) % 4 ))
      printf "\r  ${YELLOW}Searching... %c ${NC}" "${spin:$i:1}"
      sleep 0.2
    done
    printf "\r  ${GREEN}Search completed!      ${NC}\n"
  }
  
  # Process each pattern
  local pattern_index=0
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    # Trim any whitespace
    pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    echo -e "${YELLOW}Processing pattern ($(($pattern_index + 1))/${#EXCLUDE_PATTERNS[@]}): $pattern${NC}"
    debug_log "Processing exclude pattern: '$pattern'"
    
    # Handle different pattern types differently - EXACTLY as in copy_data
    if [[ "$pattern" == "**/"* ]]; then
      # Double-asterisk pattern (matches any level of directories)
      # Extract the part after **/
      dir_name="${pattern#**/}"
      # Remove trailing slash if present
      dir_name="${dir_name%/}"
      echo -e "${YELLOW}  Double-asterisk pattern: '**/$dir_name'${NC}"
      debug_pattern_log "Double-asterisk pattern: '**/$dir_name'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Run the find command in background to show progress
      (find "$source_dir" \( -path "*/$dir_name" -o -path "*/$dir_name/*" \) > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Store the find command for this pattern - will be used to build FIND_EXCLUDE_OPTS
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"*/$dir_name/\" -not -path \"*/$dir_name/*\""
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == "**/."* ]]; then
      # Double-asterisk pattern for hidden directories/files
      dir_name="${pattern#**/}"
      # Remove trailing slash if present
      dir_name="${dir_name%/}"
      echo -e "${YELLOW}  Double-asterisk hidden pattern: '**/$dir_name'${NC}"
      debug_pattern_log "Double-asterisk hidden pattern: '**/$dir_name'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Run the find command in background to show progress
      (find "$source_dir" \( -path "*/$dir_name" -o -path "*/$dir_name/*" \) > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Store the find command for this pattern - will be used to build FIND_EXCLUDE_OPTS
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"*/$dir_name/\" -not -path \"*/$dir_name/*\""
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == *"/**" ]]; then
      # Pattern ending with /** (e.g., dist/**)
      # Extract the part before /**
      dir_name="${pattern%/**}"
      echo -e "${YELLOW}  Directory wildcard pattern: '$dir_name/**'${NC}"
      debug_pattern_log "Directory wildcard pattern: '$dir_name/**'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # First find the directory itself at the top level
      if [ -d "$source_dir/$dir_name" ]; then
        EXCLUDED_DIRS+=("$source_dir/$dir_name")
        debug_pattern_log "Excluding top-level directory: $source_dir/$dir_name"
      fi
      
      # Then find any matching directories at deeper levels
      (find "$source_dir" -type d -path "*/$dir_name" > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          EXCLUDED_DIRS+=("$item")
          debug_pattern_log "Excluding directory: $item"
        fi
      done < "$output_file"
      
      # Store the find command for this pattern - this is the critical part
      # We need to exclude both the directory itself and all its contents
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"*/$dir_name\" -not -path \"*/$dir_name/*\""
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == */ ]]; then
      # Directory pattern with trailing slash
      dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash
      echo -e "${YELLOW}  Directory pattern with trailing slash: '$dir_pattern/'${NC}"
      debug_log "Directory pattern with trailing slash: '$dir_pattern'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Run the find command in background to show progress
      (find "$source_dir" \( -path "$source_dir/$dir_pattern/" -o -path "$source_dir/$dir_pattern/*" \) > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Store the find command for this pattern - will be used to build FIND_EXCLUDE_OPTS
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"$source_dir/$dir_pattern/\" -not -path \"$source_dir/$dir_pattern/*\""
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == *"/"* ]]; then
      # Path pattern (contains slash)
      echo -e "${YELLOW}  Path pattern (contains slash): '$pattern'${NC}"
      debug_log "Path pattern (contains slash): '$pattern'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Match exact path - use -path for patterns with directory separators
      if [[ "$pattern" == */ ]]; then
        # If pattern ends with slash, it's a directory
        (find "$source_dir" \( -path "$source_dir/$pattern" -o -path "$source_dir/$pattern*" \) > "$output_file") &
        local find_pid=$!
        
        # Show progress while find is running
        show_progress $find_pid
        
        # Store the find command for this pattern
        EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"$source_dir/$pattern\" -not -path \"$source_dir/$pattern*\""
      else
        # Otherwise it could be a file or directory
        (find "$source_dir" -path "$source_dir/$pattern" > "$output_file") &
        local find_pid=$!
        
        # Show progress while find is running
        show_progress $find_pid
        
        # Store the find command for this pattern
        EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"$source_dir/$pattern\""
      fi
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == \*.* ]]; then
      # File extension pattern (e.g., *.log)
      ext="${pattern#\*.}"
      echo -e "${YELLOW}  File extension pattern: '*.$ext'${NC}"
      debug_log "File extension pattern: '*.$ext'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Run the find command in background to show progress
      (find "$source_dir" -name "*.$ext" > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results - these will all be files
      while read -r item; do
        if [ -n "$item" ]; then
          EXCLUDED_FILES+=("$item")
        fi
      done < "$output_file"
      
      # Store the find command for this pattern
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -name \"*.$ext\""
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == .* ]]; then
      # Hidden file/directory pattern (starts with .)
      echo -e "${YELLOW}  Hidden file/directory pattern: '$pattern'${NC}"
      debug_log "Hidden file/directory pattern: '$pattern'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Match exact hidden file/directory name
      if [[ "$pattern" == */ ]]; then
        # If pattern ends with slash, it's a directory
        (find "$source_dir" \( -path "*/$pattern" -o -path "*/$pattern*" \) > "$output_file") &
        local find_pid=$!
        
        # Show progress while find is running
        show_progress $find_pid
        
        # Store the find command for this pattern
        EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"*/$pattern\" -not -path \"*/$pattern*\""
      else
        # Otherwise it could be a file or directory
        # Use -name for file patterns, -path for directory patterns
        (find "$source_dir" \( -name "$pattern" -o -path "*/$pattern/" -o -path "*/$pattern/*" \) > "$output_file") &
        local find_pid=$!
        
        # Show progress while find is running
        show_progress $find_pid
        
        # Store the find command for this pattern
        EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -name \"$pattern\" -not -path \"*/$pattern/\" -not -path \"*/$pattern/*\""
      fi
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Clean up
      rm -f "$output_file"
      
    elif [[ "$pattern" == *"/**" ]]; then
      # Pattern ending with /** (e.g., dist/**)
      # Extract the part before /**
      dir_name="${pattern%/**}"
      echo -e "${YELLOW}  Directory wildcard pattern: '$dir_name/**'${NC}"
      debug_pattern_log "Directory wildcard pattern: '$dir_name/**'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # First find the directory itself at the top level
      if [ -d "$source_dir/$dir_name" ]; then
        EXCLUDED_DIRS+=("$source_dir/$dir_name")
        debug_pattern_log "Excluding top-level directory: $source_dir/$dir_name"
      fi
      
      # Then find any matching directories at deeper levels
      (find "$source_dir" -type d -path "*/$dir_name" > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          EXCLUDED_DIRS+=("$item")
          debug_pattern_log "Excluding directory: $item"
        fi
      done < "$output_file"
      
      # Store the find command for this pattern - this is the critical part
      # We need to exclude both the directory itself and all its contents
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -path \"*/$dir_name\" -not -path \"*/$dir_name/*\""
      
      # Clean up
      rm -f "$output_file"
    else
      # Other patterns
      echo -e "${YELLOW}  Other pattern: '$pattern'${NC}"
      debug_log "Other pattern: '$pattern'"
      
      # Create a temporary file to store matched items
      local output_file=$(mktemp)
      
      # Run the find command in background to show progress
      (find "$source_dir" -name "$pattern" > "$output_file") &
      local find_pid=$!
      
      # Show progress while find is running
      show_progress $find_pid
      
      # Process results
      while read -r item; do
        if [ -n "$item" ]; then
          if [ -d "$item" ]; then
            EXCLUDED_DIRS+=("$item")
          elif [ -f "$item" ]; then
            EXCLUDED_FILES+=("$item")
          fi
        fi
      done < "$output_file"
      
      # Store the find command for this pattern
      EXCLUDED_PATTERN_MATCHES[$pattern_index]="-not -name \"$pattern\""
      
      # Clean up
      rm -f "$output_file"
    fi
    
    # Increment pattern index
    pattern_index=$((pattern_index + 1))
    echo
  done
  
  # Calculate total matches
  local total_dir_matches=${#EXCLUDED_DIRS[@]}
  local total_file_matches=${#EXCLUDED_FILES[@]}
  
  echo -e "${BLUE}Analysis complete. Found $total_dir_matches directories and $total_file_matches files matching patterns.${NC}"
  echo
  
  # Build the FIND_EXCLUDE_OPTS string from the pattern matches
  FIND_EXCLUDE_OPTS=""
  for pattern_match in "${EXCLUDED_PATTERN_MATCHES[@]}"; do
    FIND_EXCLUDE_OPTS+=" $pattern_match"
  done
  
  debug_log "Final find exclude options: $FIND_EXCLUDE_OPTS"
}

# Copy data based on the determined actual backup method
copy_data() {
    local source="$1"
    local destination="$2"
    
    # Ensure source has a trailing slash for rsync
    source="${source%/}/"
    
    # Check if source exists
    if [ ! -d "$source" ]; then
        echo -e "${RED}Error: Source directory does not exist: $source${NC}"
        return 1
    fi
    
    # Set up trap for clean cancellation
    trap 'global_cleanup' INT TERM
    
    # Check if dialog was shown and user has already edited exclusions
    if [ "$DIALOG_SHOWN" = true ]; then
        # Dialog was shown, respect user's choices even if arrays are empty
        echo -e "${BLUE}Using exclusion patterns from dialog selection...${NC}"
        debug_log "Using exclusion patterns from dialog: ${#EXCLUDED_FILES[@]} files, ${#EXCLUDED_DIRS[@]} directories"
        
        # If user removed all exclusions in the dialog, confirm this was intentional
        if [ ${#EXCLUDED_FILES[@]} -eq 0 ] && [ ${#EXCLUDED_DIRS[@]} -eq 0 ]; then
            echo -e "${YELLOW}Note: No files or directories will be excluded (as per your dialog selections).${NC}"
        fi
    else
        # Dialog was not shown, generate exclusions if needed
        if [ ${#EXCLUDED_FILES[@]} -eq 0 ] && [ ${#EXCLUDED_DIRS[@]} -eq 0 ] && [ -z "$FIND_EXCLUDE_OPTS" ]; then
            # Check if there are any exclusion patterns defined
            if [ ${#EXCLUDE_PATTERNS[@]} -eq 0 ]; then
                echo -e "${YELLOW}Warning: No exclusion patterns defined. All files will be included in the backup.${NC}"
                
                if [ "$NON_INTERACTIVE" = true ]; then
                    echo -e "${YELLOW}Non-interactive mode: Continuing with no exclusions${NC}"
                else
                    read -p "Continue with no exclusions? This will back up everything (y/N): " -n 1 -r no_exclusions_decision
                    echo
                    
                    # Default to "n" if user just presses Enter
                    no_exclusions_decision=${no_exclusions_decision:-n}
                    if [[ ! $no_exclusions_decision =~ ^[Yy]$ ]]; then
                        echo -e "${RED}Backup cancelled${NC}"
                        return 1
                    fi
                fi
                echo -e "${YELLOW}Proceeding with no exclusions...${NC}"
                
                # Initialize empty arrays and options
                EXCLUDED_FILES=()
                EXCLUDED_DIRS=()
                FIND_EXCLUDE_OPTS=""
            else
                # Only generate exclusions if there are patterns and the user wants to continue
                echo -e "${BLUE}Generating exclusion patterns for backup...${NC}"
                generate_exclude_matches "$source"
                
                # If no exclusions were found despite having patterns, inform the user
                if [ ${#EXCLUDED_FILES[@]} -eq 0 ] && [ ${#EXCLUDED_DIRS[@]} -eq 0 ]; then
                    echo -e "${YELLOW}Warning: No files or directories matched your exclusion patterns.${NC}"
                    
                    if [ "$NON_INTERACTIVE" = true ]; then
                        echo -e "${YELLOW}Non-interactive mode: Continuing with no exclusions${NC}"
                    else
                        read -p "Continue with no exclusions? This will back up everything (y/N): " -n 1 -r no_exclusions_decision
                        echo
                        
                        # Default to "n" if user just presses Enter
                        no_exclusions_decision=${no_exclusions_decision:-n}
                        if [[ ! $no_exclusions_decision =~ ^[Yy]$ ]]; then
                            echo -e "${RED}Backup cancelled${NC}"
                            return 1
                        fi
                    fi
                    echo -e "${YELLOW}Proceeding with no exclusions...${NC}"
                fi
            fi
        else
            # Arrays are already populated from somewhere else
            echo -e "${BLUE}Using existing exclusion patterns...${NC}"
            debug_log "Using existing exclusion patterns: ${#EXCLUDED_FILES[@]} files, ${#EXCLUDED_DIRS[@]} directories"
        fi
    fi
    
    # Debug: Show what files would be excluded by the combined patterns
    if [ "$DEBUG_MODE" = "true" ]; then
        debug_pattern_log "Files that would be excluded by the combined patterns:"
        for file in "${EXCLUDED_FILES[@]}"; do
            debug_pattern_log "  - $file"
        done
        
        debug_pattern_log "Directories that would be excluded by the combined patterns:"
        for dir in "${EXCLUDED_DIRS[@]}"; do
            debug_pattern_log "  - $dir"
        done
        
        # Generic debug check for all files
        debug_pattern_log "Summary of exclude pattern effects:"
        debug_pattern_log "  Total files in source: $(find \"$source\" -type f | wc -l)"
        debug_pattern_log "  Files that will be excluded: ${#EXCLUDED_FILES[@]}"
        debug_pattern_log "  Directories that will be excluded: ${#EXCLUDED_DIRS[@]}"
        debug_pattern_log "  Final find exclude options: $FIND_EXCLUDE_OPTS"
    fi
    
    # Determine the actual method to use based on available tools
    determine_actual_backup_method
    
    echo -e "${YELLOW}Copying data using $ACTUAL_BACKUP_METHOD method...${NC}"
    echo -e "${YELLOW}Error handling mode: $ERROR_HANDLING${NC}"
    
    # Reset failed files list
    FAILED_FILES=()
    
    case "$ACTUAL_BACKUP_METHOD" in
        tar)
            # Get source size for progress estimation
            SOURCE_SIZE=$(du -sb "$source" | awk '{print $1}')
            
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use tar with error handling that continues on errors
                local error_log=$(mktemp)
                
                eval "(cd \"$source\" && tar cf - . 2>\"$error_log\") | \
                    pv -s \"$SOURCE_SIZE\" -name \"Copying data\" | \
                    (cd \"$destination\" && tar xf -)"
                
                # Check for errors in the log
                if [ -s "$error_log" ]; then
                    echo -e "${YELLOW}Some files could not be copied:${NC}"
                    cat "$error_log" | grep -v "^tar: " | while read -r line; do
                        echo -e "${YELLOW}  - $line${NC}"
                        FAILED_FILES+=("$line")
                    done
                    rm "$error_log"
                fi
            else
                # Use tar with strict error handling (default behavior)
                eval "(cd \"$source\" && tar cf - .) | \
                    pv -s \"$SOURCE_SIZE\" -name \"Copying data\" | \
                    (cd \"$destination\" && tar xf -)" || {
                    echo -e "${RED}Failed to copy data${NC}"
                    return 1
                }
            fi
            ;;
        parallel)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use parallel with error handling that continues on errors
                local error_log=$(mktemp)
                
                echo -e "${BLUE}Copying files using parallel method...${NC}"
                debug_log "Starting parallel backup with error handling=continue"
                debug_log "Source path: $source"
                
                # Ensure source path is normalized (remove trailing slash if present)
                local normalized_source="${source%/}"
                debug_log "Normalized source path: $normalized_source"
                
                # First create the directory structure
                echo -e "${BLUE}Creating directory structure...${NC}"
                debug_log "Creating directory structure..."
                eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                    # Extract relative path correctly regardless of trailing slash
                    rel_dir="${dir#$normalized_source}"
                    rel_dir="${rel_dir#/}"  # Remove leading slash if present
                    debug_log "Original dir: $dir"
                    debug_log "Extracted rel_dir: $rel_dir"
                    if [ -n "$rel_dir" ]; then
                        debug_log "Creating directory: $destination/$rel_dir"
                        mkdir -p "$destination/$rel_dir"
                    fi
                done
                
                # Copy files in parallel with error handling
                echo -e "${BLUE}Copying files...${NC}"
                
                # Create a temporary file with the list of files to copy
                local files_list=$(mktemp)
                debug_log "Files list: $files_list"
                
                # Use standard find command for regular files
                eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > "$files_list"
                
                local total_files=$(wc -l < "$files_list")
                echo -e "${YELLOW}Copying $total_files files in parallel...${NC}"
                
                # Debug: Show the list of files that will be copied
                if [ "$DEBUG_MODE" = "true" ]; then
                    debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                    cat "$files_list" | while read -r file; do
                        debug_pattern_log "  - $file"
                    done
                fi
                
                # First try a simpler approach - process files one by one for better reliability
                debug_log "Processing files one by one..."
                while read -r file; do
                    # Extract relative path correctly regardless of trailing slash
                    rel_file="${file#$normalized_source}"
                    rel_file="${rel_file#/}"  # Remove leading slash if present
                    debug_log "Original file: $file"
                    debug_log "Extracted rel_file: $rel_file"
                    
                    # Create parent directory if it doesn't exist
                    parent_dir="$(dirname "$destination/$rel_file")"
                    if [ ! -d "$parent_dir" ]; then
                        debug_log "Creating parent directory: $parent_dir"
                        mkdir -p "$parent_dir"
                    fi
                    
                    debug_log "Copying $file to $destination/$rel_file"
                    cp -a --reflink=auto "$file" "$destination/$rel_file" 2>>"$error_log" || true
                done < "$files_list"
                
                # Clean up
                debug_log "Cleaning up temporary files..."
                rm -f "$files_list"
                
                # Check for errors in the log
                if [ -s "$error_log" ]; then
                    echo -e "${YELLOW}Some files could not be copied:${NC}"
                    debug_log "Errors detected:"
                    cat "$error_log" | while read -r line; do
                        echo -e "${YELLOW}  - $line${NC}"
                        debug_log "  - $line"
                        FAILED_FILES+=("$line")
                    done
                    rm "$error_log"
                fi
                
                if [ "$DEBUG_MODE" = true ]; then
                    debug_log "Debug log contents:"
                    debug_log "Destination directory listing:"
                    ls -la "$destination" >> "$DEBUG_LOG"
                    debug_log "Destination directory structure:"
                    find "$destination" -type d | sort >> "$DEBUG_LOG"
                    debug_log "Destination files:"
                    find "$destination" -type f | sort >> "$DEBUG_LOG"
                fi
            else
                # Use parallel with strict error handling
                # Ensure source path is normalized (remove trailing slash if present)
                local normalized_source="${source%/}"
                debug_log "Normalized source path: $normalized_source"
                
                # First create the directory structure
                echo -e "${BLUE}Creating directory structure...${NC}"
                debug_log "Creating directory structure..."
                eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                    # Extract relative path correctly regardless of trailing slash
                    rel_dir="${dir#$normalized_source}"
                    rel_dir="${rel_dir#/}"  # Remove leading slash if present
                    debug_log "Original dir: $dir"
                    debug_log "Extracted rel_dir: $rel_dir"
                    if [ -n "$rel_dir" ]; then
                        debug_log "Creating directory: $destination/$rel_dir"
                        mkdir -p "$destination/$rel_dir" || {
                            echo -e "${RED}Failed to create directory: $destination/$rel_dir${NC}"
                            debug_log "Failed to create directory: $destination/$rel_dir"
                            return 1
                        }
                    fi
                done
                
                # Copy files with strict error handling
                echo -e "${BLUE}Copying files...${NC}"
                
                # Create a temporary file with the list of files to copy
                local files_list=$(mktemp)
                debug_log "Files list: $files_list"
                
                # Use standard find command for regular files
                eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > "$files_list"
                
                local total_files=$(wc -l < "$files_list")
                echo -e "${YELLOW}Copying $total_files files...${NC}"
                
                # Debug: Show the list of files that will be copied
                if [ "$DEBUG_MODE" = "true" ]; then
                    debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                    cat "$files_list" | while read -r file; do
                        debug_pattern_log "  - $file"
                    done
                fi
                
                # Process files one by one for better reliability
                debug_log "Processing files one by one..."
                while read -r file; do
                    # Extract relative path correctly regardless of trailing slash
                    rel_file="${file#$normalized_source}"
                    rel_file="${rel_file#/}"  # Remove leading slash if present
                    debug_log "Original file: $file"
                    debug_log "Extracted rel_file: $rel_file"
                    
                    # Create parent directory if it doesn't exist
                    parent_dir="$(dirname "$destination/$rel_file")"
                    if [ ! -d "$parent_dir" ]; then
                        debug_log "Creating parent directory: $parent_dir"
                        mkdir -p "$parent_dir"
                    fi
                    
                    debug_log "Copying $file to $destination/$rel_file"
                    cp -a --reflink=auto "$file" "$destination/$rel_file" || {
                        echo -e "${RED}Failed to copy: $file to $destination/$rel_file${NC}"
                        debug_log "Failed to copy: $file to $destination/$rel_file"
                        rm -f "$files_list"
                        return 1
                    }
                done < "$files_list"
                
                # Clean up
                debug_log "Cleaning up temporary files..."
                rm -f "$files_list"
                
                if [ "$DEBUG_MODE" = true ]; then
                    debug_log "Debug log contents:"
                    debug_log "Destination directory listing:"
                    ls -la "$destination" >> "$DEBUG_LOG"
                    debug_log "Destination directory structure:"
                    find "$destination" -type d | sort >> "$DEBUG_LOG"
                    debug_log "Destination files:"
                    find "$destination" -type f | sort >> "$DEBUG_LOG"
                fi
            fi
            ;;
        cp-progress)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use cp with error handling that continues on errors
                local error_log=$(mktemp)
                
                # When using exclude patterns with cp-progress, we need to use find
                if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
                    echo -e "${YELLOW}Using find with exclude patterns for cp-progress method${NC}"
                    
                    # Create destination directories first
                    eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                        rel_dir="${dir#$source}"
                        if [ -n "$rel_dir" ]; then
                            mkdir -p "$destination/$rel_dir"
                        fi
                    done
                    
                    # Copy files with progress
                    eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > /tmp/files_to_copy.txt
                    total_files=$(wc -l < /tmp/files_to_copy.txt)
                    echo -e "${YELLOW}Copying $total_files files...${NC}"
                    
                    # Debug: Show the list of files that will be copied
                    if [ "$DEBUG_MODE" = "true" ]; then
                        debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                        cat /tmp/files_to_copy.txt | while read -r file; do
                            debug_pattern_log "  - $file"
                        done
                    fi
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
                        
                        # Create parent directory if it doesn't exist
                        parent_dir="$(dirname "$destination/$rel_file")"
                        if [ ! -d "$parent_dir" ]; then
                            debug_log "Creating parent directory: $parent_dir"
                            mkdir -p "$parent_dir"
                        fi
                        
                        cp -a --reflink=auto "$file" "$destination/$rel_file" 2>>"$error_log" || true
                    done
                    
                    rm /tmp/files_to_copy.txt
                else
                    # Start cp in background with error logging (original method)
                    # Copy all files including hidden ones
                    shopt -s dotglob
                    cp -a --reflink=auto "$source"/* "$destination"/ 2>"$error_log" & 
                    shopt -u dotglob
                    CP_PID=$!
                    progress -mp $CP_PID
                    wait $CP_PID
                fi
                
                # Check for errors in the log
                if [ -s "$error_log" ]; then
                    echo -e "${YELLOW}Some files could not be copied:${NC}"
                    cat "$error_log" | while read -r line; do
                        echo -e "${YELLOW}  - $line${NC}"
                        FAILED_FILES+=("$line")
                    done
                    rm "$error_log"
                fi
            else
                # Use cp with strict error handling
                # When using exclude patterns with cp-progress, we need to use find
                if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
                    echo -e "${YELLOW}Using find with exclude patterns for cp-progress method${NC}"
                    
                    # Create destination directories first
                    eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                        rel_dir="${dir#$source}"
                        if [ -n "$rel_dir" ]; then
                            mkdir -p "$destination/$rel_dir"
                        fi
                    done
                    
                    # Copy files with progress
                    eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > /tmp/files_to_copy.txt
                    total_files=$(wc -l < /tmp/files_to_copy.txt)
                    echo -e "${YELLOW}Copying $total_files files...${NC}"
                    
                    # Debug: Show the list of files that will be copied
                    if [ "$DEBUG_MODE" = "true" ]; then
                        debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                        cat /tmp/files_to_copy.txt | while read -r file; do
                            debug_pattern_log "  - $file"
                        done
                    fi
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
                        
                        # Create parent directory if it doesn't exist
                        parent_dir="$(dirname "$destination/$rel_file")"
                        if [ ! -d "$parent_dir" ]; then
                            debug_log "Creating parent directory: $parent_dir"
                            mkdir -p "$parent_dir"
                        fi
                        
                        cp -a --reflink=auto "$file" "$destination/$rel_file" || {
                            echo -e "${RED}Failed to copy file: $file${NC}"
                            rm /tmp/files_to_copy.txt
                            return 1
                        }
                    done
                    
                    rm /tmp/files_to_copy.txt
                else
                    # Copy all files including hidden ones (original method)
                    shopt -s dotglob
                    cp -a --reflink=auto "$source"/* "$destination"/ & 
                    shopt -u dotglob
                    CP_PID=$!
                    progress -mp $CP_PID
                    wait $CP_PID || { 
                        echo -e "${RED}Failed to copy data${NC}"
                        return 1
                    }
                fi
            fi
            ;;
        cp-plain|*)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use cp with error handling that continues on errors
                local error_log=$(mktemp)
                
                # When using exclude patterns with cp-plain, we need to use find
                if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
                    echo -e "${YELLOW}Using find with exclude patterns for cp-plain method${NC}"
                    
                    # Create destination directories first
                    eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                        rel_dir="${dir#$source}"
                        if [ -n "$rel_dir" ]; then
                            mkdir -p "$destination/$rel_dir"
                        fi
                    done
                    
                    # Copy files
                    eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > /tmp/files_to_copy.txt
                    total_files=$(wc -l < /tmp/files_to_copy.txt)
                    echo -e "${YELLOW}Copying $total_files files...${NC}"
                    
                    # Debug: Show the list of files that will be copied
                    if [ "$DEBUG_MODE" = "true" ]; then
                        debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                        cat /tmp/files_to_copy.txt | while read -r file; do
                            debug_pattern_log "  - $file"
                        done
                    fi
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
                        
                        # Create parent directory if it doesn't exist
                        parent_dir="$(dirname "$destination/$rel_file")"
                        if [ ! -d "$parent_dir" ]; then
                            debug_log "Creating parent directory: $parent_dir"
                            mkdir -p "$parent_dir"
                        fi
                        
                        cp -a --reflink=auto "$file" "$destination/$rel_file" 2>>"$error_log" || true
                    done
                    
                    rm /tmp/files_to_copy.txt
                else
                    # Copy with error logging - include hidden files (original method)
                    shopt -s dotglob
                    cp -a --reflink=auto "$source"/* "$destination"/ 2>"$error_log" || true
                    shopt -u dotglob
                fi
                
                # Check for errors in the log
                if [ -s "$error_log" ]; then
                    echo -e "${YELLOW}Some files could not be copied:${NC}"
                    cat "$error_log" | while read -r line; do
                        echo -e "${YELLOW}  - $line${NC}"
                        FAILED_FILES+=("$line")
                    done
                    rm "$error_log"
                fi
            else
                # Use cp with strict error handling
                # When using exclude patterns with cp-plain, we need to use find
                if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
                    echo -e "${YELLOW}Using find with exclude patterns for cp-plain method${NC}"
                    
                    # Create destination directories first
                    eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                        rel_dir="${dir#$source}"
                        if [ -n "$rel_dir" ]; then
                            mkdir -p "$destination/$rel_dir"
                        fi
                    done
                    
                    # Copy files
                    eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > /tmp/files_to_copy.txt
                    total_files=$(wc -l < /tmp/files_to_copy.txt)
                    echo -e "${YELLOW}Copying $total_files files...${NC}"
                    
                    # Debug: Show the list of files that will be copied
                    if [ "$DEBUG_MODE" = "true" ]; then
                        debug_pattern_log "Files that will be copied (after applying all exclude patterns):"
                        cat /tmp/files_to_copy.txt | while read -r file; do
                            debug_pattern_log "  - $file"
                        done
                    fi
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
                        
                        # Create parent directory if it doesn't exist
                        parent_dir="$(dirname "$destination/$rel_file")"
                        if [ ! -d "$parent_dir" ]; then
                            debug_log "Creating parent directory: $parent_dir"
                            mkdir -p "$parent_dir"
                        fi
                        
                        cp -a --reflink=auto "$file" "$destination/$rel_file" || {
                            echo -e "${RED}Failed to copy file: $file${NC}"
                            rm /tmp/files_to_copy.txt
                            return 1
                        }
                    done
                    
                    rm /tmp/files_to_copy.txt
                else
                    # Copy all files including hidden ones (original method)
                    shopt -s dotglob
                    cp -a --reflink=auto "$source"/* "$destination"/ || { 
                        echo -e "${RED}Failed to copy data${NC}"
                        return 1
                    }
                    shopt -u dotglob
                fi
            fi
            ;;
    esac
    
    # Report summary of failed files if any
    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Warning: ${#FAILED_FILES[@]} files could not be copied${NC}"
        echo -e "${YELLOW}The backup was created but may be missing some files${NC}"
        
        # If not in non-interactive mode, ask if user wants to see the list
        if [ "$NON_INTERACTIVE" = true ] && [ ${#FAILED_FILES[@]} -gt 10 ]; then
            echo -e "${YELLOW}Non-interactive mode: Skipping failed files list${NC}"
        else
            read -p "Do you want to see the complete list of failed files? (y/N): " -n 1 -r show_files
            echo
            
            # Default to "n" if user just presses Enter
            show_files=${show_files:-n}
            
            if [[ $show_files =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Failed files:${NC}"
                for file in "${FAILED_FILES[@]}"; do
                    echo -e "${YELLOW}  - $file${NC}"
                done
            fi
        fi
        
        # Return success but with a specific code to indicate partial success
        return 2
    else
        echo -e "${GREEN}All files copied successfully${NC}"
    fi
    
    # Reset trap
    trap - INT TERM
    echo -e "${GREEN}Backup completed${NC}"
    return 0
}

# Process exclude files and add patterns to EXCLUDE_PATTERNS
process_exclude_files() {
  for exclude_file in "${EXCLUDE_FILES[@]}"; do
    # Expand tilde to home directory if present
    expanded_file=$(eval echo "$exclude_file")
    
    if [ -f "$expanded_file" ]; then
      echo -e "${YELLOW}Reading exclude patterns from: $expanded_file${NC}"
      debug_log "Reading exclude patterns from: $expanded_file"
      while IFS= read -r pattern || [ -n "$pattern" ]; do
        # Skip empty lines and comments
        if [[ -n "$pattern" && ! "$pattern" =~ ^[[:space:]]*# ]]; then
          # Trim leading and trailing whitespace
          pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
          if [ -n "$pattern" ]; then
            EXCLUDE_PATTERNS+=("$pattern")
            debug_log "Added exclude pattern: '$pattern'"
          fi
        fi
      done < "$expanded_file"
    else
      echo -e "${RED}Warning: Exclude file not found: $exclude_file${NC}"
      debug_log "Warning: Exclude file not found: $exclude_file"
    fi
  done
  
  # Log all patterns for debugging
  if [ "$DEBUG_MODE" = true ] && [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    debug_log "All exclude patterns:"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
      debug_log "  - '$pattern'"
    done
  fi
}

# Preview files that will be excluded based on patterns
preview_excluded_files() {
  if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ] && [ -d "$SOURCE_DIR" ]; then
    echo -e "${BLUE}Previewing files that will be excluded:${NC}"
    
    # Build find command to show excluded files
    local find_cmd="find \"$SOURCE_DIR\" \\( "
    local first=true
    
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
      if [[ "$pattern" == */ ]]; then
        # Directory pattern with trailing slash
        dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash
        if [ "$first" = true ]; then
          find_cmd+=" -path \"*/$dir_pattern/*\" -o -path \"*/$dir_pattern\""
          first=false
        else
          find_cmd+=" -o -path \"*/$dir_pattern/*\" -o -path \"*/$dir_pattern\""
        fi
      elif [[ "$pattern" == *"/"* ]]; then
        # Path pattern (contains slash)
        if [ "$first" = true ]; then
          find_cmd+=" -path \"$pattern*\""
          first=false
        else
          find_cmd+=" -o -path \"$pattern*\""
        fi
      elif [[ "$pattern" == \*.* ]]; then
        # File extension pattern (e.g., *.log)
        ext="${pattern#\*.}"
        if [ "$first" = true ]; then
          find_cmd+=" -name \"*.$ext\""
          first=false
        else
          find_cmd+=" -o -name \"*.$ext\""
        fi
      else
        # Other patterns
        if [ "$first" = true ]; then
          find_cmd+=" -name \"$pattern\""
          first=false
        else
          find_cmd+=" -o -name \"$pattern\""
        fi
      fi
    done
    
    find_cmd+=" \\) -type f | sort"
    
    # Execute the find command to show excluded files
    local excluded_files=$(eval "$find_cmd")
    local excluded_count=$(echo "$excluded_files" | grep -v "^$" | wc -l)
    
    if [ $excluded_count -gt 0 ]; then
      echo -e "${YELLOW}Found $excluded_count files that will be excluded:${NC}"
      
      # If there are too many files, ask before showing all
      if [ $excluded_count -gt 20 ] && [ "$NON_INTERACTIVE" != true ]; then
        read -p "There are $excluded_count files to be excluded. Show all? (y/N): " -n 1 -r show_all
        echo
        
        if [[ $show_all =~ ^[Yy]$ ]]; then
          echo "$excluded_files" | sed "s|^$SOURCE_DIR/||" | while read -r file; do
            if [ -n "$file" ]; then
              echo -e "${YELLOW}  - $file${NC}"
            fi
          done
        else
          # Show just the first 10 files
          echo "$excluded_files" | sed "s|^$SOURCE_DIR/||" | head -n 10 | while read -r file; do
            if [ -n "$file" ]; then
              echo -e "${YELLOW}  - $file${NC}"
            fi
          done
          echo -e "${YELLOW}  ... and $(($excluded_count - 10)) more files${NC}"
        fi
      else
        # Show all excluded files (there are 20 or fewer)
        echo "$excluded_files" | sed "s|^$SOURCE_DIR/||" | while read -r file; do
          if [ -n "$file" ]; then
            echo -e "${YELLOW}  - $file${NC}"
          fi
        done
      fi
    else
      echo -e "${YELLOW}No files match the exclude patterns.${NC}"
    fi
    
    # Also show a count of files that will be included
    local total_files=$(find "$SOURCE_DIR" -type f | wc -l)
    local included_files=$((total_files - excluded_count))
    echo -e "${GREEN}$included_files out of $total_files files will be included in the backup.${NC}"
    echo
  fi
}

# Edit exclude patterns interactively
edit_exclude_patterns() {
  local temp_patterns=("${EXCLUDE_PATTERNS[@]}")
  EXCLUDE_PATTERNS=()
  
  echo -e "${BLUE}You can now review and modify each exclude pattern:${NC}"
  echo -e "${BLUE}(Press Enter to keep, type new value to modify, or type 'delete' to remove)${NC}"
  echo
  
  # Edit existing patterns
  if [ ${#temp_patterns[@]} -gt 0 ]; then
    local i=0
    for pattern in "${temp_patterns[@]}"; do
      i=$((i+1))
      echo -e "${YELLOW}[$i/${#temp_patterns[@]}] Current pattern: $pattern${NC}"
      read -p "New pattern (Enter to keep, 'delete' to remove): " new_pattern
      
      if [ -z "$new_pattern" ]; then
        # Keep original pattern
        EXCLUDE_PATTERNS+=("$pattern")
        echo -e "${GREEN}Pattern kept: $pattern${NC}"
      elif [ "$new_pattern" = "delete" ]; then
        # Skip this pattern (effectively deleting it)
        echo -e "${RED}Pattern deleted: $pattern${NC}"
      else
        # Use the new pattern
        EXCLUDE_PATTERNS+=("$new_pattern")
        echo -e "${GREEN}Pattern updated: $new_pattern${NC}"
      fi
      echo
    done
  fi
  
  # Allow adding new patterns
  while true; do
    read -p "Add new exclude pattern? (Enter to skip, or type new pattern): " new_pattern
    if [ -z "$new_pattern" ]; then
      break
    else
      EXCLUDE_PATTERNS+=("$new_pattern")
      echo -e "${GREEN}New pattern added: $new_pattern${NC}"
    fi
  done
  
  # Show final list of patterns
  echo
  echo -e "${YELLOW}Final exclude patterns:${NC}"
  if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
      echo -e "${YELLOW}  - $pattern${NC}"
    done
  else
    echo -e "${YELLOW}  (No patterns selected)${NC}"
  fi
}

# Show exclude patterns to the user
show_exclude_patterns() {
  if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    echo -e "${YELLOW}The following exclude patterns will be applied:${NC}"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
      echo -e "${YELLOW}  - $pattern${NC}"
    done
    
    # If in interactive mode, offer to edit patterns
    if [ "$NON_INTERACTIVE" != true ]; then
      # Offer to preview excluded files
      read -p "Would you like to see which files will be excluded? (y/N): " -n 1 -r preview_decision
      echo
      
      if [[ $preview_decision =~ ^[Yy]$ ]]; then
        preview_excluded_files
      fi
      
      # Offer to edit patterns
      read -p "Would you like to edit the exclude patterns? (y/N): " -n 1 -r edit_decision
      echo
      
      if [[ $edit_decision =~ ^[Yy]$ ]]; then
        edit_exclude_patterns
        
        # After editing, offer to preview again
        if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
          read -p "Would you like to see which files will be excluded with the updated patterns? (y/N): " -n 1 -r preview_again
          echo
          
          if [[ $preview_again =~ ^[Yy]$ ]]; then
            preview_excluded_files
          fi
        fi
      fi
      
      read -p "Continue with these exclude patterns? (Y/n): " -n 1 -r continue_decision
      echo
      
      # Default to "y" if user just presses Enter
      continue_decision=${continue_decision:-y}
      
      if [[ ! $continue_decision =~ ^[Yy]$ ]]; then
        echo -e "${RED}Operation cancelled${NC}"
        exit 1
      fi
    fi
  else
    echo -e "${YELLOW}No exclude patterns specified.${NC}"
    
    # If in interactive mode, offer to add patterns
    if [ "$NON_INTERACTIVE" != true ]; then
      read -p "Would you like to add exclude patterns? (y/N): " -n 1 -r add_patterns
      echo
      
      if [[ $add_patterns =~ ^[Yy]$ ]]; then
        edit_exclude_patterns
        
        # After adding patterns, offer to preview
        if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
          read -p "Would you like to see which files will be excluded? (y/N): " -n 1 -r preview_decision
          echo
          
          if [[ $preview_decision =~ ^[Yy]$ ]]; then
            preview_excluded_files
          fi
          
          read -p "Continue with these exclude patterns? (Y/n): " -n 1 -r continue_decision
          echo
          
          # Default to "y" if user just presses Enter
          continue_decision=${continue_decision:-y}
          
          if [[ ! $continue_decision =~ ^[Yy]$ ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 1
          fi
        fi
      fi
    fi
  fi
}

# Check if dialog is installed
check_dialog() {
  if ! command -v dialog >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: dialog is not installed. Interactive exclude selection requires dialog.${NC}"
    echo -e "${YELLOW}You can install it with:${NC}"
    echo -e "${YELLOW}  - On Debian/Ubuntu: sudo apt-get install dialog${NC}"
    echo -e "${YELLOW}  - On Arch Linux: sudo pacman -S dialog${NC}"
    echo -e "${YELLOW}  - On Fedora: sudo dnf install dialog${NC}"
    echo -e "${YELLOW}Continuing without interactive exclude selection...${NC}"
    SHOW_EXCLUDED=false
    return 1
  fi
  return 0
}

# Interactive exclude selection using dialog
interactive_exclude_selection() {
    local source_dir="$1"
    
    # Create temporary directory for dialog files
    local temp_dir=$(mktemp -d)
    local temp_file="$temp_dir/dialog_output"
    
    # Check if dialog is installed
    if ! command -v dialog >/dev/null 2>&1; then
        echo -e "${RED}Error: dialog command not found. Please install dialog package.${NC}"
        return 1
    fi
    
    # Generate exclude matches using the shared function
    generate_exclude_matches "$source_dir"
    
    # Process each pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        # Trim any whitespace
        pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Skip empty patterns
        if [ -z "$pattern" ]; then
            continue
        fi
        
        echo -e "${BLUE}Showing matches for pattern: $pattern${NC}"
        
        # Filter the excluded files and directories for this pattern
        local pattern_files=()
        local pattern_dirs=()
        
        # For each excluded file, check if it matches the current pattern
        for file in "${EXCLUDED_FILES[@]}"; do
            # Check if the file matches this pattern
            if [[ "$file" == *"$pattern"* ]] || [[ "$file" =~ $pattern ]]; then
                pattern_files+=("$file")
            fi
        done
        
        # For each excluded directory, check if it matches the current pattern
        for dir in "${EXCLUDED_DIRS[@]}"; do
            # Check if the directory matches this pattern
            if [[ "$dir" == *"$pattern"* ]] || [[ "$dir" =~ $pattern ]]; then
                pattern_dirs+=("$dir")
            fi
        done
        
        # Combine files and directories
        local all_items=("${pattern_files[@]}" "${pattern_dirs[@]}")
        
        # If no matches found, continue to next pattern
        if [ ${#all_items[@]} -eq 0 ]; then
            echo -e "${YELLOW}No matches found for pattern: $pattern${NC}"
            continue
        fi
        
        # Build dialog items
        local dialog_items=""
        local i=1
        
        for item in "${all_items[@]}"; do
            # Get relative path
            local rel_path="${item#$source_dir/}"
            
            # Check if it's a directory or file
            if [ -d "$item" ]; then
                dialog_items+="\"$i\" \"$rel_path/ (dir)\" on "
            else
                dialog_items+="\"$i\" \"$rel_path\" on "
            fi
            
            i=$((i + 1))
        done
        
        # Show the checklist for files/directories
        eval "dialog --title \"Files/Directories for Pattern: $pattern\" --backtitle \"BTRFS Backup Utility\" \
            --checklist \"Select items to exclude (Space to toggle, Enter to confirm):\" 20 70 15 \
            $dialog_items 2> $temp_file"
        
        # Get the selected items
        if [ -s "$temp_file" ]; then
            local selected_indices=$(cat "$temp_file")
            
            # Process selected indices
            if [ -n "$selected_indices" ]; then
                # Convert the selected indices to an array
                local selected_array=()
                for index in $selected_indices; do
                    # Remove quotes if present
                    index=${index//\"/}
                    selected_array+=($index)
                done
                
                # Create a new array for items to keep
                local keep_items=()
                
                # Loop through all items and keep only those not selected
                for ((j=1; j<=${#all_items[@]}; j++)); do
                    # Check if this index is in the selected array
                    if ! [[ " ${selected_array[@]} " =~ " $j " ]]; then
                        # This item was not selected, so keep it
                        keep_items+=("${all_items[$j-1]}")
                    fi
                done
                
                # Replace the original arrays with the filtered ones
                local new_excluded_files=()
                local new_excluded_dirs=()
                
                # Add all excluded files that were not in the current pattern
                for file in "${EXCLUDED_FILES[@]}"; do
                    if ! [[ " ${all_items[@]} " =~ " $file " ]] || [[ " ${keep_items[@]} " =~ " $file " ]]; then
                        new_excluded_files+=("$file")
                    fi
                done
                
                # Add all excluded directories that were not in the current pattern
                for dir in "${EXCLUDED_DIRS[@]}"; do
                    if ! [[ " ${all_items[@]} " =~ " $dir " ]] || [[ " ${keep_items[@]} " =~ " $dir " ]]; then
                        new_excluded_dirs+=("$dir")
                    fi
                done
                
                # Update the arrays
                EXCLUDED_FILES=("${new_excluded_files[@]}")
                EXCLUDED_DIRS=("${new_excluded_dirs[@]}")
                
                # Rebuild FIND_EXCLUDE_OPTS based on the updated exclusion lists
                FIND_EXCLUDE_OPTS=""
                for file in "${EXCLUDED_FILES[@]}"; do
                    FIND_EXCLUDE_OPTS+=" -not -path \"$file\""
                done
                
                for dir in "${EXCLUDED_DIRS[@]}"; do
                    FIND_EXCLUDE_OPTS+=" -not -path \"$dir\" -not -path \"$dir/*\""
                done
            fi
        fi
    done
    
    # Set flag to indicate dialog was shown and user has edited exclusions
    DIALOG_SHOWN=true
    
    # Clean up
    rm -rf "$temp_dir"
    
    return 0
}

# Main backup function
do_backup() {
    # Validate required parameters
    if [ -z "$SOURCE_DIR" ]; then
        echo -e "${RED}Error: Source directory not specified${NC}"
        show_help
        exit 1
    fi
    
    if [ -z "$DESTINATION_DIR" ]; then
        echo -e "${RED}Error: Destination directory not specified${NC}"
        show_help
        exit 1
    fi
    
    # Check if source exists
    if [ ! -d "$SOURCE_DIR" ]; then
        echo -e "${RED}Error: Source directory does not exist: $SOURCE_DIR${NC}"
        exit 1
    fi
    
    # Check if destination exists, create if not
    if [ ! -d "$DESTINATION_DIR" ]; then
        echo -e "${YELLOW}Creating destination directory: $DESTINATION_DIR${NC}"
        mkdir -p "$DESTINATION_DIR" || {
            echo -e "${RED}Failed to create destination directory${NC}"
            exit 1
        }
    fi
    
    # Process exclude files
    process_exclude_files
    
    # Create a new subvolume if needed
    if [ "$CREATE_SUBVOLUME" = true ]; then
        create_subvolume
    fi
    
    # Show interactive exclude selection if requested
    if [ "$SHOW_EXCLUDED" = true ]; then
        interactive_exclude_selection "$SOURCE_DIR"
        # If user cancelled, exit
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}Backup cancelled.${NC}"
            exit 0
        fi
    else
        show_exclude_patterns
    fi
    
    # Check if source is empty and ask for confirmation
    if [ -z "$(ls -A "$SOURCE_DIR")" ]; then
        echo -e "${RED}Warning: Source directory appears to be empty.${NC}"
        
        if [ "$NON_INTERACTIVE" = true ]; then
            echo -e "${YELLOW}Non-interactive mode: Continuing with empty source${NC}"
        else
            read -p "Continue with empty source? This will create an empty backup (Y/n): " -n 1 -r empty_backup_decision
            echo
            
            # Default to "y" if user just presses Enter
            empty_backup_decision=${empty_backup_decision:-y}
            if [[ ! $empty_backup_decision =~ ^[Yy]$ ]]; then
                echo -e "${RED}Operation cancelled${NC}"
                exit 1
            fi
        fi
        echo -e "${YELLOW}Proceeding with empty source...${NC}"
        
        # Create an empty destination
        echo -e "${GREEN}Empty backup created${NC}"
        return 0
    fi
    
    # Perform the backup
    echo -e "${BLUE}Starting backup from $SOURCE_DIR to $DESTINATION_DIR${NC}"
    copy_data "$SOURCE_DIR" "$DESTINATION_DIR"
    return $?
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--source)
                SOURCE_DIR="$2"
                shift 2
                ;;
            -d|--destination)
                DESTINATION_DIR="$2"
                shift 2
                ;;
            -m|--method)
                BACKUP_METHOD="$2"
                shift 2
                ;;
            --method=*)
                BACKUP_METHOD="${1#*=}"
                # Validate the method
                case "$BACKUP_METHOD" in
                    tar|parallel)
                        # Valid method
                        ;;
                    *)
                        echo -e "${RED}Error: Invalid backup method: $BACKUP_METHOD${NC}"
                        echo -e "${YELLOW}Valid methods: tar, parallel${NC}"
                        exit 1
                        ;;
                esac
                shift
                ;;
            -e|--error-handling)
                ERROR_HANDLING="$2"
                shift 2
                ;;
            --error-handling=*)
                ERROR_HANDLING="${1#*=}"
                # Validate the error handling mode
                case "$ERROR_HANDLING" in
                    strict|continue)
                        # Valid mode
                        ;;
                    *)
                        echo -e "${RED}Error: Invalid error handling mode: $ERROR_HANDLING${NC}"
                        echo -e "${YELLOW}Valid modes: strict, continue${NC}"
                        exit 1
                        ;;
                esac
                shift
                ;;
            -n|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --exclude=*)
                EXCLUDE_PATTERNS+=("${1#*=}")
                shift
                ;;
            --exclude-from=*)
                EXCLUDE_FILES+=("${1#*=}")
                shift
                ;;
            --show-excluded)
                SHOW_EXCLUDED=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                DEBUG_LOG=$(mktemp)
                echo "Debug mode enabled. Log file: $DEBUG_LOG" >&2
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Validate incompatible options with non-interactive mode
    if [ "$NON_INTERACTIVE" = true ]; then
        if [ "$SHOW_EXCLUDED" = true ]; then
            echo -e "${RED}Error: --show-excluded cannot be used with --non-interactive mode${NC}"
            echo -e "${YELLOW}In non-interactive mode, exclusion patterns must be specified via --exclude or --exclude-from${NC}"
            exit 1
        fi
    fi
}

# Script execution starts here
parse_arguments "$@"
do_backup
exit $?
