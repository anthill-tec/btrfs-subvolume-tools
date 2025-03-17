#!/bin/bash
# logging.sh - Contains functions for the phase-based logging system

# Initialize global variables for log files
PHASE1_LOG=""
PHASE2_LOG=""
PHASE3_LOG=""
PHASE4_LOG=""
PHASE5_LOG=""
SUMMARY_LOG=""

# Set up logging directory structure and initialize log files
setup_logging() {
    local container_name="$1"
    
    # Create log directories
    LOG_BASE_DIR="tests/logs"
    LOG_SESSION_DIR="$LOG_BASE_DIR/$container_name"
    mkdir -p "$LOG_SESSION_DIR"
    
    # Initialize log files for each phase
    PHASE1_LOG="$LOG_SESSION_DIR/01_pre_installation.log"
    PHASE2_LOG="$LOG_SESSION_DIR/02_tool_setup.log"
    PHASE3_LOG="$LOG_SESSION_DIR/03_test_configuration.log"
    PHASE4_LOG="$LOG_SESSION_DIR/04_test_execution.log"
    PHASE5_LOG="$LOG_SESSION_DIR/05_cleanup_results.log"
    
    # Create empty log files
    > "$PHASE1_LOG"
    > "$PHASE2_LOG"
    > "$PHASE3_LOG"
    > "$PHASE4_LOG"
    > "$PHASE5_LOG"
    
    # Create a summary log
    SUMMARY_LOG="$LOG_SESSION_DIR/00_summary.log"
    
    # Add header to summary log
    echo "======================================================" > "$SUMMARY_LOG"
    echo "  Test Session: $container_name" >> "$SUMMARY_LOG"
    echo "  Started at: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SUMMARY_LOG"
    echo "======================================================" >> "$SUMMARY_LOG"
    echo "" >> "$SUMMARY_LOG"
    echo "PHASE SUMMARY:" >> "$SUMMARY_LOG"
    echo "" >> "$SUMMARY_LOG"
    
    # Return the log directory for reference
    echo "$LOG_SESSION_DIR"
}

# Log a message and optionally execute a command, capturing its output
log_to_phase() {
    local phase_num="$1"
    local message="$2"
    local command="$3"
    local log_file
    
    # Select the appropriate log file
    case "$phase_num" in
        1) log_file="$PHASE1_LOG" ;;
        2) log_file="$PHASE2_LOG" ;;
        3) log_file="$PHASE3_LOG" ;;
        4) log_file="$PHASE4_LOG" ;;
        5) log_file="$PHASE5_LOG" ;;
        *) echo "Invalid phase number: $phase_num"; return 1 ;;
    esac
    
    # Add a timestamp and message
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$log_file"
    
    # If a command was provided, execute it and log its output
    if [ -n "$command" ]; then
        echo "" >> "$log_file"  # Empty line for readability
        echo "===== COMMAND: $command =====" >> "$log_file"
        echo "" >> "$log_file"  # Empty line for readability
        
        # Execute command and capture its output to the log file
        eval "$command" >> "$log_file" 2>&1
        local cmd_status=$?
        
        if [ $cmd_status -ne 0 ]; then
            echo "" >> "$log_file"  # Empty line for readability
            echo "Command failed with exit code $cmd_status" >> "$log_file"
        fi
        
        echo "" >> "$log_file"  # Empty line for readability
        echo "===== END COMMAND OUTPUT =====" >> "$log_file"
        echo "" >> "$log_file"  # Empty line for readability
    fi
    
    # Also log to the summary file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Phase $phase_num: $message" >> "$SUMMARY_LOG"
    
    # Also print to stdout for real-time monitoring
    echo "Phase $phase_num: $message"
    
    # Return the command's exit status if there was a command
    if [ -n "$command" ]; then
        return $cmd_status
    fi
    return 0
}

# Add a final summary to the log
finalize_log_summary() {
    local result_code="$1"
    local test_duration="$2"
    
    echo "" >> "$SUMMARY_LOG"
    echo "======================================================" >> "$SUMMARY_LOG"
    echo "  Test Result: $([ $result_code -eq 0 ] && echo "SUCCESS" || echo "FAILURE")" >> "$SUMMARY_LOG"
    echo "  Exit Code: $result_code" >> "$SUMMARY_LOG"
    echo "  Completed at: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SUMMARY_LOG"
    echo "  Duration: $test_duration seconds" >> "$SUMMARY_LOG"
    echo "======================================================" >> "$SUMMARY_LOG"
    
    # Add file locations for easy reference
    echo "" >> "$SUMMARY_LOG"
    echo "LOG FILES:" >> "$SUMMARY_LOG"
    echo "  Phase 1 (Pre-installation): $PHASE1_LOG" >> "$SUMMARY_LOG"
    echo "  Phase 2 (Tool Setup): $PHASE2_LOG" >> "$SUMMARY_LOG"
    echo "  Phase 3 (Test Configuration): $PHASE3_LOG" >> "$SUMMARY_LOG"
    echo "  Phase 4 (Test Execution): $PHASE4_LOG" >> "$SUMMARY_LOG"
    echo "  Phase 5 (Cleanup & Results): $PHASE5_LOG" >> "$SUMMARY_LOG"
}