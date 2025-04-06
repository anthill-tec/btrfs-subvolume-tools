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

# Debug logging function
debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] $1" >> "$DEBUG_LOG"
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

# Copy data based on the determined actual backup method
copy_data() {
    local source="$1"
    local destination="$2"
    
    # Determine the actual method to use based on available tools
    determine_actual_backup_method
    
    echo -e "${YELLOW}Copying data using $ACTUAL_BACKUP_METHOD method...${NC}"
    echo -e "${YELLOW}Error handling mode: $ERROR_HANDLING${NC}"
    
    # Reset failed files list
    FAILED_FILES=()
    
    # Set up trap for clean cancellation
    trap 'global_cleanup' INT TERM
    
    # Build exclude options for tar
    TAR_EXCLUDE_OPTS=""
    if [ "$INTERACTIVE_EXCLUDE_MODE" != "true" ] && [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            TAR_EXCLUDE_OPTS+=" --exclude='$pattern'"
        done
    fi
    
    # Build find exclude options for parallel and cp methods
    FIND_EXCLUDE_OPTS=""
    if [ "$INTERACTIVE_EXCLUDE_MODE" != "true" ] && [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        debug_log "Building find exclude options from ${#EXCLUDE_PATTERNS[@]} patterns"
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            # Trim any whitespace
            pattern=$(echo "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            debug_log "Processing exclude pattern: '$pattern'"
            
            # Handle different pattern types differently
            if [[ "$pattern" == */ ]]; then
                # Directory pattern with trailing slash
                dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash
                debug_log "Directory pattern with trailing slash: '$dir_pattern'"
                FIND_EXCLUDE_OPTS+=" -not -path \"$source/$dir_pattern/*\" -not -path \"$source/$dir_pattern\""
            elif [[ "$pattern" == *"/"* ]]; then
                # Path pattern (contains slash)
                debug_log "Path pattern (contains slash): '$pattern'"
                FIND_EXCLUDE_OPTS+=" -not -path \"$source/$pattern*\""
            elif [[ "$pattern" == \*.* ]]; then
                # File extension pattern (e.g., *.log)
                ext="${pattern#\*.}"
                debug_log "File extension pattern: '*.$ext'"
                FIND_EXCLUDE_OPTS+=" -not -name \"*.$ext\""
            else
                # Other patterns
                debug_log "Other pattern: '$pattern'"
                FIND_EXCLUDE_OPTS+=" -not -name \"$pattern\""
            fi
        done
        debug_log "Final find exclude options: $FIND_EXCLUDE_OPTS"
    fi
    
    case "$ACTUAL_BACKUP_METHOD" in
        tar)
            # Get source size for progress estimation
            SOURCE_SIZE=$(du -sb "$source" | awk '{print $1}')
            
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use tar with error handling that continues on errors
                local error_log=$(mktemp)
                
                eval "(cd \"$source\" && tar $TAR_EXCLUDE_OPTS cf - . 2>\"$error_log\") | \
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
                eval "(cd \"$source\" && tar $TAR_EXCLUDE_OPTS cf - .) | \
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
                
                # First create the directory structure
                echo -e "${BLUE}Creating directory structure...${NC}"
                debug_log "Creating directory structure..."
                eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                    rel_dir="${dir#$source}"
                    if [ -n "$rel_dir" ]; then
                        debug_log "Creating directory: $destination$rel_dir"
                        mkdir -p "$destination$rel_dir"
                    fi
                done
                
                # Copy files in parallel with error handling
                echo -e "${BLUE}Copying files...${NC}"
                
                # Create a temporary file with the list of files to copy
                local files_list=$(mktemp)
                debug_log "Files list: $files_list"
                eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > "$files_list"
                local total_files=$(wc -l < "$files_list")
                echo -e "${YELLOW}Copying $total_files files in parallel...${NC}"
                
                # First try a simpler approach - process files one by one for better reliability
                debug_log "Processing files one by one..."
                while read -r file; do
                    rel_file="${file#$source}"
                    debug_log "Copying file: $file to $destination$rel_file"
                    cp -a --reflink=auto "$file" "$destination$rel_file" 2>>"$error_log" || {
                        echo "Failed to copy: $file to $destination$rel_file" >> "$error_log"
                        debug_log "Failed to copy: $file to $destination$rel_file"
                    }
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
                # First create the directory structure
                echo -e "${BLUE}Creating directory structure...${NC}"
                debug_log "Creating directory structure..."
                eval "find \"$source\" -type d $FIND_EXCLUDE_OPTS" | while read -r dir; do
                    rel_dir="${dir#$source}"
                    if [ -n "$rel_dir" ]; then
                        debug_log "Creating directory: $destination$rel_dir"
                        mkdir -p "$destination$rel_dir" || {
                            echo -e "${RED}Failed to create directory: $destination$rel_dir${NC}"
                            debug_log "Failed to create directory: $destination$rel_dir"
                            return 1
                        }
                    fi
                done
                
                # Copy files with strict error handling
                echo -e "${BLUE}Copying files...${NC}"
                
                # Create a temporary file with the list of files to copy
                local files_list=$(mktemp)
                debug_log "Files list: $files_list"
                eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > "$files_list"
                local total_files=$(wc -l < "$files_list")
                echo -e "${YELLOW}Copying $total_files files...${NC}"
                
                # Process files one by one for better reliability
                debug_log "Processing files one by one..."
                while read -r file; do
                    rel_file="${file#$source}"
                    debug_log "Copying file: $file to $destination$rel_file"
                    cp -a --reflink=auto "$file" "$destination$rel_file" || {
                        echo -e "${RED}Failed to copy: $file to $destination$rel_file${NC}"
                        debug_log "Failed to copy: $file to $destination$rel_file"
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
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
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
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
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
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
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
                            mkdir -p "$destination/$rel_dir" || {
                                echo -e "${RED}Failed to create directory: $destination/$rel_dir${NC}"
                                return 1
                            }
                        fi
                    done
                    
                    # Copy files
                    eval "find \"$source\" -type f $FIND_EXCLUDE_OPTS" > /tmp/files_to_copy.txt
                    total_files=$(wc -l < /tmp/files_to_copy.txt)
                    echo -e "${YELLOW}Copying $total_files files...${NC}"
                    
                    cat /tmp/files_to_copy.txt | while read -r file; do
                        rel_file="${file#$source/}"
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
        if [ "$NON_INTERACTIVE" != true ] && [ ${#FAILED_FILES[@]} -gt 10 ]; then
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
      if [[ "$pattern" == *"/"* ]]; then
        # Directory pattern (contains slash)
        dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash if present
        if [ "$first" = true ]; then
          find_cmd+=" -path \"*/$dir_pattern/*\" -o -path \"*/$dir_pattern\""
          first=false
        else
          find_cmd+=" -o -path \"*/$dir_pattern/*\" -o -path \"*/$dir_pattern\""
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
  # Check if dialog is installed
  if ! check_dialog; then
    return 1
  fi
  
  # Temporary file for dialog output
  local temp_file=$(mktemp)
  
  # Step 1: Collect information about excluded files/directories by pattern
  echo -e "${BLUE}Analyzing exclude patterns...${NC}"
  
  # Arrays to store excluded files by pattern
  declare -A pattern_file_count
  declare -A pattern_dir_count
  declare -A selected_patterns
  
  # Initialize all patterns as selected
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    selected_patterns["$pattern"]=1
    pattern_file_count["$pattern"]=0
    pattern_dir_count["$pattern"]=0
  done
  
  # Count files and directories matched by each pattern
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$pattern" == */ ]]; then
      # Directory pattern with trailing slash
      dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash if present
      
      # Count directories matching this pattern
      local dirs=$(find "$SOURCE_DIR" \( -path "*/$dir_pattern/*" -o -path "*/$dir_pattern" \) -type d | wc -l)
      pattern_dir_count["$pattern"]=$dirs
      
      # Count total files in these directories
      local files=0
      find "$SOURCE_DIR" \( -path "*/$dir_pattern/*" -o -path "*/$dir_pattern" \) -type d | while read -r dir; do
        if [ -n "$dir" ]; then
          local dir_files=$(find "$dir" -type f | wc -l)
          files=$((files + dir_files))
        fi
      done
      pattern_file_count["$pattern"]=$files
      
    elif [[ "$pattern" == *"/"* ]]; then
      # Path pattern (contains slash)
      local files=$(find "$SOURCE_DIR" -path "$pattern" -type f | wc -l)
      pattern_file_count["$pattern"]=$files
      
    elif [[ "$pattern" == \*.* ]]; then
      # File extension pattern (e.g., *.log)
      ext="${pattern#\*.}"
      
      # Count files matching this pattern
      local files=$(find "$SOURCE_DIR" -name "*.$ext" -type f | wc -l)
      pattern_file_count["$pattern"]=$files
      
    else
      # Other patterns
      local files=$(find "$SOURCE_DIR" -name "$pattern" -type f | wc -l)
      pattern_file_count["$pattern"]=$files
    fi
  done
  
  # Step 2: Show pattern selection dialog
  local dialog_items=""
  local item_count=0
  
  # Build dialog items for patterns
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    item_count=$((item_count + 1))
    local file_count=${pattern_file_count["$pattern"]}
    local dir_count=${pattern_dir_count["$pattern"]}
    
    # Add pattern to dialog items with counts
    if [ $dir_count -gt 0 ]; then
      dialog_items+="\"p$item_count\" \"$pattern ($dir_count dirs, $file_count files)\" ${selected_patterns["$pattern"]} "
    elif [ $file_count -gt 0 ]; then
      dialog_items+="\"p$item_count\" \"$pattern ($file_count files)\" ${selected_patterns["$pattern"]} "
    else
      dialog_items+="\"p$item_count\" \"$pattern (no matches)\" ${selected_patterns["$pattern"]} "
    fi
  done
  
  # If no patterns have matches, show a message and return
  local total_matches=0
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    total_matches=$((total_matches + ${pattern_file_count["$pattern"]} + ${pattern_dir_count["$pattern"]}))
  done
  
  if [ $total_matches -eq 0 ]; then
    dialog --title "Exclude Patterns" --backtitle "BTRFS Backup Utility" \
      --msgbox "No files or directories match the specified exclude patterns.\n\nAll files will be included in the backup." 10 60
    rm -f "$temp_file"
    return 0
  fi
  
  # Run dialog checklist for patterns
  eval "dialog --title \"Exclude Patterns\" --backtitle \"BTRFS Backup Utility\" \
    --checklist \"Select patterns to exclude (Space to toggle, Enter to confirm):\" 20 70 10 \
    $dialog_items 2> $temp_file"
  
  # Check dialog exit status
  if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Exclude selection cancelled.${NC}"
    rm -f "$temp_file"
    return 1
  fi
  
  # Read selected patterns
  local selected_pattern_ids=$(cat "$temp_file")
  
  # Update pattern selection based on user choices
  for i in $(seq 1 $item_count); do
    local pattern_idx=$((i - 1))
    local pattern="${EXCLUDE_PATTERNS[$pattern_idx]}"
    
    if echo "$selected_pattern_ids" | grep -q "p$i"; then
      selected_patterns["$pattern"]=1
    else
      selected_patterns["$pattern"]=0
    fi
  done
  
  # Filter EXCLUDE_PATTERNS based on user selections
  local filtered_patterns=()
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if [ ${selected_patterns["$pattern"]} -eq 1 ]; then
      filtered_patterns+=("$pattern")
    fi
  done
  
  EXCLUDE_PATTERNS=("${filtered_patterns[@]}")
  
  # Step 3: For each selected pattern, show file/directory selection dialog
  declare -A excluded_files
  declare -A excluded_dirs
  
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    # Skip patterns with no matches
    if [ ${pattern_file_count["$pattern"]} -eq 0 ] && [ ${pattern_dir_count["$pattern"]} -eq 0 ]; then
      continue
    fi
    
    # Arrays to store matched files and directories
    local matched_files=()
    local matched_dirs=()
    
    # Find files and directories matched by this pattern
    if [[ "$pattern" == *"/"* ]]; then
      # Directory pattern (contains slash)
      dir_pattern=$(echo "$pattern" | sed 's|/$||') # Remove trailing slash if present
      
      # Find directories matching this pattern
      while read -r dir; do
        if [ -n "$dir" ]; then
          local file_count=$(find "$dir" -type f | wc -l)
          matched_dirs+=("$dir ($file_count files)")
          excluded_dirs["$dir"]=1
        fi
      done < <(find "$SOURCE_DIR" \( -path "*/$dir_pattern/*" -o -path "*/$dir_pattern" \) -type d | sort)
      
    elif [[ "$pattern" == \*.* ]]; then
      # File extension pattern (e.g., *.log)
      ext="${pattern#\*.}"
      
      # Find files matching this pattern
      while read -r file; do
        if [ -n "$file" ]; then
          matched_files+=("$file")
          excluded_files["$file"]=1
        fi
      done < <(find "$SOURCE_DIR" -name "*.$ext" -type f | sort)
      
    else
      # Other patterns
      while read -r file; do
        if [ -n "$file" ]; then
          matched_files+=("$file")
          excluded_files["$file"]=1
        fi
      done < <(find "$SOURCE_DIR" -name "$pattern" -type f | sort)
    fi
    
    # Build dialog items for files and directories
    local dialog_items=""
    local item_count=0
    
    # Add directories to the list
    for dir_entry in "${matched_dirs[@]}"; do
      item_count=$((item_count + 1))
      local dir="${dir_entry%% (*}"
      dialog_items+="\"d$item_count\" \"$dir_entry\" 1 "
    done
    
    # Add files to the list (limit to 100 files for performance)
    local file_count=0
    for file in "${matched_files[@]}"; do
      file_count=$((file_count + 1))
      if [ $file_count -le 100 ]; then
        item_count=$((item_count + 1))
        dialog_items+="\"f$item_count\" \"$file\" 1 "
      fi
    done
    
    # If there are more than 100 files, add a note
    if [ $file_count -gt 100 ]; then
      dialog_items+="\"more\" \"... and $(($file_count - 100)) more files (not shown)\" 0 "
    fi
    
    # Skip if no items to show
    if [ -z "$dialog_items" ]; then
      continue
    fi
    
    # Show the checklist for files/directories
    eval "dialog --title \"Files/Directories for Pattern: $pattern\" --backtitle \"BTRFS Backup Utility\" \
      --checklist \"Select items to exclude (Space to toggle, Enter to confirm):\" 20 70 15 \
      $dialog_items 2> $temp_file"
    
    # Check dialog exit status
    if [ $? -ne 0 ]; then
      # User cancelled, keep all files/dirs for this pattern
      continue
    fi
    
    # Read selected items
    local selected_items=$(cat "$temp_file")
    
    # Update file/directory status based on selection
    for i in $(seq 1 $item_count); do
      if echo "$dialog_items" | grep -q "\"d$i\""; then
        # This is a directory
        local dir_entry=$(echo "$dialog_items" | grep -o "\"d$i\" \"[^\"]*\"" | cut -d'"' -f4)
        local dir="${dir_entry%% (*}"
        
        if echo "$selected_items" | grep -q "d$i"; then
          # Directory was selected for exclusion
          excluded_dirs["$dir"]=1
        else
          # Directory was deselected
          excluded_dirs["$dir"]=0
        fi
      elif echo "$dialog_items" | grep -q "\"f$i\""; then
        # This is a file
        local file=$(echo "$dialog_items" | grep -o "\"f$i\" \"[^\"]*\"" | cut -d'"' -f4)
        
        if echo "$selected_items" | grep -q "f$i"; then
          # File was selected for exclusion
          excluded_files["$file"]=1
        else
          # File was deselected
          excluded_files["$file"]=0
        fi
      fi
    done
  done
  
  # Step 4: Build custom find and tar exclude options based on selections
  FIND_EXCLUDE_OPTS=""
  TAR_EXCLUDE_OPTS=""
  
  # Add selected directories to exclude options
  for dir in "${!excluded_dirs[@]}"; do
    if [ ${excluded_dirs["$dir"]} -eq 1 ]; then
      rel_dir="${dir#$SOURCE_DIR/}"
      FIND_EXCLUDE_OPTS+=" -not -path \"$dir/*\" -not -path \"$dir\""
      TAR_EXCLUDE_OPTS+=" --exclude='$rel_dir'"
    fi
  done
  
  # Add selected files to exclude options
  for file in "${!excluded_files[@]}"; do
    if [ ${excluded_files["$file"]} -eq 1 ]; then
      rel_file="${file#$SOURCE_DIR/}"
      FIND_EXCLUDE_OPTS+=" -not -path \"$file\""
      TAR_EXCLUDE_OPTS+=" --exclude='$rel_file'"
    fi
  done
  
  # Show summary of what will be excluded
  local total_excluded_dirs=0
  local total_excluded_files=0
  
  for dir in "${!excluded_dirs[@]}"; do
    if [ ${excluded_dirs["$dir"]} -eq 1 ]; then
      total_excluded_dirs=$((total_excluded_dirs + 1))
    fi
  done
  
  for file in "${!excluded_files[@]}"; do
    if [ ${excluded_files["$file"]} -eq 1 ]; then
      total_excluded_files=$((total_excluded_files + 1))
    fi
  done
  
  dialog --title "Exclude Summary" --backtitle "BTRFS Backup Utility" \
    --msgbox "The backup will exclude:\n\n- $total_excluded_dirs directories\n- $total_excluded_files files\n\nSelected patterns will be applied to the backup process." 10 60
  
  # Clean up
  rm -f "$temp_file"
  
  # Override the default exclude pattern processing
  # This ensures the interactive selections take precedence
  # over the default pattern-based exclusions in copy_data
  INTERACTIVE_EXCLUDE_MODE=true
  
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
    
    # Show interactive exclude selection if requested
    if [ "$SHOW_EXCLUDED" = true ]; then
      interactive_exclude_selection
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
}

# Script execution starts here
parse_arguments "$@"
do_backup
exit $?
