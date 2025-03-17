#!/bin/bash
# A simpler logging system for the BTRFS Subvolume Tools tests with debug mode support

# Global log directory
LOG_DIR=""

# Debug mode flag - can be set from the environment
DEBUG_MODE="${DEBUG_MODE:-false}"

# Initialize the logging system
init_logging() {
    local container_name="$1"
    
    # Create log directory structure
    LOG_DIR="tests/logs/$container_name"
    mkdir -p "$LOG_DIR"
    
    # Create and initialize the summary log
    local summary_file="$LOG_DIR/00_summary.log"
    cat > "$summary_file" << EOF
==================================================
  BTRFS Subvolume Tools Test Run
  Session: $container_name
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Debug Mode: $DEBUG_MODE
==================================================

EOF
    
    # Create empty phase log files
    touch "$LOG_DIR/01_pre_installation.log"
    touch "$LOG_DIR/02_tool_setup.log"
    touch "$LOG_DIR/03_test_configuration.log"
    touch "$LOG_DIR/04_test_execution.log"
    touch "$LOG_DIR/05_cleanup_results.log"
    
    # Return the log directory
    echo "$LOG_DIR"
}

# Log a message to a specific phase
log_phase() {
    local phase="$1"
    local message="$2"
    
    # Map phase number to log file
    local log_file
    case "$phase" in
        1) log_file="$LOG_DIR/01_pre_installation.log" ;;
        2) log_file="$LOG_DIR/02_tool_setup.log" ;;
        3) log_file="$LOG_DIR/03_test_configuration.log" ;;
        4) log_file="$LOG_DIR/04_test_execution.log" ;;
        5) log_file="$LOG_DIR/05_cleanup_results.log" ;;
        *)
            echo "Invalid phase number: $phase"
            return 1
            ;;
    esac
    
    # Append message to the phase log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$log_file"
    
    # Also add to summary
    echo "[Phase $phase] $message" >> "$LOG_DIR/00_summary.log"
    
    # Print to console
    echo "Phase $phase: $message"
}

# Execute a command and log its output
run_cmd() {
    local phase="$1"
    local cmd_desc="$2"
    local command="$3"
    
    # Log the command
    log_phase "$phase" "$cmd_desc"
    
    # Map phase number to log file
    local log_file
    case "$phase" in
        1) log_file="$LOG_DIR/01_pre_installation.log" ;;
        2) log_file="$LOG_DIR/02_tool_setup.log" ;;
        3) log_file="$LOG_DIR/03_test_configuration.log" ;;
        4) log_file="$LOG_DIR/04_test_execution.log" ;;
        5) log_file="$LOG_DIR/05_cleanup_results.log" ;;
        *)
            echo "Invalid phase number: $phase"
            return 1
            ;;
    esac
    
    # Create a clear command block header in the log
    cat >> "$log_file" << EOF

-------------------------------------------------
COMMAND: $command
-------------------------------------------------

EOF
    
    # Run the command and capture output
    # Deliberately use a subshell to isolate redirection
    (
        set -o pipefail
        # In debug mode, output to both log file and console
        # In normal mode, output only to log file
        if [ "$DEBUG_MODE" = "true" ]; then
            eval "$command" 2>&1 | tee -a "$log_file"
        else
            eval "$command" >> "$log_file" 2>&1
        fi
    )
    local status=${PIPESTATUS[0]}
    
    # Log the command status
    cat >> "$log_file" << EOF

-------------------------------------------------
COMMAND EXIT STATUS: $status
-------------------------------------------------

EOF
    
    return $status
}

# Finalize the logs with a summary
finalize_logs() {
    local result="$1"
    local duration="$2"
    
    # Add the summary footer
    cat >> "$LOG_DIR/00_summary.log" << EOF

==================================================
  Test Results
--------------------------------------------------
  Result: $([ "$result" -eq 0 ] && echo "SUCCESS" || echo "FAILURE")
  Exit Code: $result
  Duration: $duration seconds
  Completed: $(date '+%Y-%m-%d %H:%M:%S')
  Debug Mode: $DEBUG_MODE
==================================================

EOF

    # If there was a failure and we're not in debug mode, suggest enabling debug mode
    if [ "$result" -ne 0 ] && [ "$DEBUG_MODE" != "true" ]; then
        echo "Tests failed. For more detailed output, run with DEBUG_MODE=true:"
        echo "  DEBUG_MODE=true sudo make test"
        echo "Full logs are available at: $LOG_DIR"
    fi
}

# Set debug mode from environment variable
set_debug_mode() {
    local mode="${1:-false}"
    DEBUG_MODE="$mode"
}