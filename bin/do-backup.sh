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
# List to track files that failed to copy
FAILED_FILES=()

# Global variable for process IDs
CP_PID=""

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
  echo
  echo "Example:"
  echo "  $0 --source /home/user --destination /mnt/backup/home"
  echo "  $0 -s /var -d /mnt/backup/var --method=parallel"
  echo "  $0 -s /home/user -d /mnt/backup/home --error-handling=continue"
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
    
    case "$ACTUAL_BACKUP_METHOD" in
        tar)
            # Get source size for progress estimation
            SOURCE_SIZE=$(du -sb "$source" | awk '{print $1}')
            
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use tar with error handling that continues on errors
                local error_log=$(mktemp)
                
                (cd "$source" && tar cf - . 2>"$error_log") | \
                    pv -s "$SOURCE_SIZE" -name "Copying data" | \
                    (cd "$destination" && tar xf -)
                
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
                (cd "$source" && tar cf - .) | \
                    pv -s "$SOURCE_SIZE" -name "Copying data" | \
                    (cd "$destination" && tar xf -) || {
                        echo -e "${RED}Failed to copy data${NC}"
                        return 1
                    }
            fi
            ;;
        parallel)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use parallel with error handling that continues on errors
                local error_log=$(mktemp)
                
                # Copy files with parallel, logging errors
                find "$source" -type f -print0 | \
                    parallel --progress --bar --will-cite -0 \
                    "cp --parents {} \"$destination\"/ 2>\"$error_log\" || echo \"Failed to copy: {}\" >> \"$error_log\""
                
                # Copy directories (these rarely fail)
                find "$source" -type d -print0 | \
                    parallel -0 mkdir -p "$destination/{/.}"
                
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
                # Use parallel with strict error handling
                find "$source" -type f -print0 | \
                    parallel --progress --bar --will-cite -0 cp --parents {} "$destination"/ || {
                        echo -e "${RED}Failed to copy data${NC}"
                        return 1
                    }
                
                # Copy directories and special files that parallel might have missed
                find "$source" -type d -print0 | \
                    parallel -0 mkdir -p "$destination/{/.}" || {
                        echo -e "${RED}Failed to create directories${NC}"
                        return 1
                    }
            fi
            ;;
        cp-progress)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use cp with error handling that continues on errors
                local error_log=$(mktemp)
                
                # Start cp in background with error logging
                # Copy all files including hidden ones
                shopt -s dotglob
                cp -a --reflink=auto "$source"/* "$destination"/ 2>"$error_log" & 
                shopt -u dotglob
                CP_PID=$!
                progress -mp $CP_PID
                wait $CP_PID
                
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
                # Copy all files including hidden ones
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
            ;;
        cp-plain|*)
            if [ "$ERROR_HANDLING" = "continue" ]; then
                # Use cp with error handling that continues on errors
                local error_log=$(mktemp)
                
                # Copy with error logging - include hidden files
                shopt -s dotglob
                cp -a --reflink=auto "$source"/* "$destination"/ 2>"$error_log" || true
                shopt -u dotglob
                
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
                # Copy all files including hidden ones
                shopt -s dotglob
                cp -a --reflink=auto "$source"/* "$destination"/ || { 
                    echo -e "${RED}Failed to copy data${NC}"
                    return 1
                }
                shopt -u dotglob
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
