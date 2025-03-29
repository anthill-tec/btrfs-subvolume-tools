#!/bin/bash
# Modified version of the logging.sh file to improve test output visibility
# This change focuses on controlling what appears on the console while maintaining
# detailed logging to files

# Global log directory
LOG_DIR=""

# Define color codes for better visibility
# Make sure to use -e with echo to interpret these escape sequences
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m" # No Color

# Force color output even when output is not a terminal
export FORCE_COLOR=true

# Debug mode flag - can be set from the environment
export DEBUG=${DEBUG:-false}

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
  ${PROJECT_NAME:-Project} Test Run
  Session: $container_name
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Debug Mode: $DEBUG
==================================================

EOF
    
    # Create log files based on debug mode
    if [ "$DEBUG" = "true" ]; then
        # Detailed logs for DEBUG mode
        touch "$LOG_DIR/01_pre_installation.log"
        touch "$LOG_DIR/02_tool_setup.log"
        touch "$LOG_DIR/03_test_configuration.log"
        touch "$LOG_DIR/04_test_execution.log"
        touch "$LOG_DIR/05_cleanup_results.log"
    else
        # In normal mode, just create a single test output file besides summary
        touch "$LOG_DIR/test_output.log"
    fi
    
    # Return the log directory
    echo "$LOG_DIR"
}

# Log a message to a specific phase
log_phase() {
    local phase="$1"
    local message="$2"
    
    # Map phase number to log file
    local log_file
    local phase_color
    
    # Set color for each phase
    case "$phase" in
        1) phase_color="${CYAN}" ;;
        2) phase_color="${GREEN}" ;;
        3) phase_color="${YELLOW}" ;;
        4) phase_color="${BLUE}" ;;
        5) phase_color="${PURPLE}" ;;
        *) phase_color="${BOLD}" ;;
    esac
    
    if [ "$DEBUG" = "true" ]; then
        # Detailed logging in debug mode
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
    else
        # In normal mode, log everything to the test_output file
        log_file="$LOG_DIR/test_output.log"
    fi
    
    # Append message to the phase log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$log_file"
    
    # Also add to summary
    echo "[Phase $phase] $message" >> "$LOG_DIR/00_summary.log"
    
    # Print to console in both normal and debug modes
    echo -e "${phase_color}Phase $phase:${NC} $message"
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
    if [ "$DEBUG" = "true" ]; then
        # Detailed logging in debug mode
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
    else
        # In normal mode, log everything to the test_output file
        log_file="$LOG_DIR/test_output.log"
    fi
    
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
        # In normal mode, output only to log file EXCEPT for test execution phase
        if [ "$DEBUG" = "true" ]; then
            # In debug mode, show all output
            eval "$command" 2>&1 | tee -a "$log_file"
        elif [ "$phase" = "4" ]; then
            # For test execution phase in normal mode, only show output for specific commands
            # This reduces verbosity while still showing important test results
            if [[ "$cmd_desc" == *"Running tests in container with"* ]]; then
                # Show output for the actual test run
                eval "$command" 2>&1 | tee -a "$log_file"
            else
                # For other phase 4 commands, just log without showing output
                eval "$command" >> "$log_file" 2>&1
            fi
        else
            # For other phases in normal mode, only log, don't show
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
    local result=$1
    local duration=$2
    
    # Add a summary to the log file
    cat >> "$LOG_DIR/00_summary.log" << EOF

==================================================
  Test Session Results
--------------------------------------------------
  Result: $([ "$result" -eq 0 ] && echo "SUCCESS" || echo "FAILURE")
  Exit Code: $result
  Duration: $duration seconds
  Completed: $(date '+%Y-%m-%d %H:%M:%S')
  Debug Mode: $DEBUG
==================================================

EOF

    # Always show this summary information regardless of debug mode
    echo ""
    echo -e "${BOLD}====================================================${NC}"
    echo -e "${BOLD}  Test Session Results${NC}"
    echo -e "${BOLD}----------------------------------------------------${NC}"
    if [ "$result" -eq 0 ]; then
        echo -e "  Result: ${GREEN}SUCCESS${NC}"
    else
        echo -e "  Result: ${RED}FAILURE${NC}"
    fi
    echo -e "  Exit Code: $result"
    echo -e "  Duration: $duration seconds"
    echo -e "  Completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}====================================================${NC}"
    
    # If there was a failure and we're not in debug mode, suggest enabling debug mode
    if [ "$result" -ne 0 ] && [ "$DEBUG" != "true" ]; then
        echo -e "${YELLOW}Tests failed. For more detailed output, run with DEBUG=true:${NC}"
        echo -e "  ${BOLD}DEBUG=true sudo make test${NC}"
        echo -e "Full logs are available at: ${BLUE}$LOG_DIR${NC}"
    else
        echo -e "Test logs saved to: ${BLUE}$LOG_DIR${NC}"
    fi
}

# Set debug mode from environment variable
set_debug_mode() {
    local mode="${1:-false}"
    DEBUG="$mode"
    # Export the variable to make it available to child processes
    export DEBUG
}