#!/bin/bash
# Test suite for the pattern-matcher module
# Tests the pattern matching functionality independently

# Global test variables
TEST_DIR=""
SOURCE_DIR=""
TEST_TEMP_DIR="${TEST_TEMP_DIR:-/tmp/btrfs-test}"

# Debug mode flag - can be set from the environment
DEBUG="${DEBUG:-false}"

# Setup test environment 
setup() {
    # Create test temp directory if it doesn't exist
    mkdir -p "$TEST_TEMP_DIR"
    
    TEST_DIR="$TEST_TEMP_DIR/pattern-matcher-test"
    mkdir -p "$TEST_DIR"
    
    SOURCE_DIR="$TEST_DIR/source"
    mkdir -p "$SOURCE_DIR"
    
    logDebug "Test directory: $TEST_DIR"
    logDebug "Source directory: $SOURCE_DIR"
    
    # First, try to directly source the pattern-matcher.sh file
    # This is a more direct approach that bypasses the module-loader
    PATTERN_MATCHER_PATH=""
    
    # Check common locations in container environment
    for path in \
        "/root/share/btrfs-subvolume-tools/lib/pattern-matcher.sh" \
        "/root/share/lib/pattern-matcher.sh" \
        "$HOME/share/btrfs-subvolume-tools/lib/pattern-matcher.sh" \
        "/usr/share/btrfs-subvolume-tools/lib/pattern-matcher.sh" \
        "/usr/local/share/btrfs-subvolume-tools/lib/pattern-matcher.sh"; do
        
        if [ -f "$path" ]; then
            PATTERN_MATCHER_PATH="$path"
            break
        fi
    done
    
    # If not found in common locations, try to find it
    if [ -z "$PATTERN_MATCHER_PATH" ]; then
        PATTERN_MATCHER_PATH=$(find /root -name "pattern-matcher.sh" 2>/dev/null | head -n 1)
    fi
    
    # If we found the pattern-matcher.sh file, source it directly
    if [ -n "$PATTERN_MATCHER_PATH" ]; then
        logInfo "Found pattern-matcher at: $PATTERN_MATCHER_PATH"
        source "$PATTERN_MATCHER_PATH"
        logInfo "Pattern-matcher module loaded successfully"
    else
        # Fall back to module-loader if direct sourcing fails
        logInfo "Pattern-matcher not found directly, trying module-loader"
        
        # Set up module path - first check container path, then try local path as fallback
        MODULE_PATH=""
        for path in \
            "/root/share/btrfs-subvolume-tools/lib/module-loader.sh" \
            "/root/share/lib/module-loader.sh" \
            "$HOME/share/btrfs-subvolume-tools/lib/module-loader.sh" \
            "/usr/share/btrfs-subvolume-tools/lib/module-loader.sh" \
            "/usr/local/share/btrfs-subvolume-tools/lib/module-loader.sh"; do
            
            if [ -f "$path" ]; then
                MODULE_PATH="$path"
                break
            fi
        done
        
        # If not found in common locations, try to find it
        if [ -z "$MODULE_PATH" ]; then
            MODULE_PATH=$(find /root -name "module-loader.sh" 2>/dev/null | head -n 1)
        fi
        
        if [ -z "$MODULE_PATH" ]; then
            logError "Could not locate module-loader.sh"
            return 1
        fi
        
        logInfo "Using module loader: $MODULE_PATH"
        source "$MODULE_PATH"
        
        # Load the pattern-matcher module
        if ! load_module "pattern-matcher"; then
            logError "Could not load pattern-matcher module"
            return 1
        fi
        
        logInfo "Pattern-matcher module loaded successfully via module-loader"
    fi
    
    # Create test directory structure
    create_test_files
    
    return 0
}

# Create test files and directories
create_test_files() {
    logInfo "Creating test files and directories..."
    
    # Create test directories
    mkdir -p "$SOURCE_DIR/dir1/subdir1"
    mkdir -p "$SOURCE_DIR/dir2/subdir2"
    mkdir -p "$SOURCE_DIR/test_dir"
    mkdir -p "$SOURCE_DIR/logs"
    mkdir -p "$SOURCE_DIR/cache"
    
    # Create test files
    touch "$SOURCE_DIR/file1.txt"
    touch "$SOURCE_DIR/file2.log"
    touch "$SOURCE_DIR/file3.tmp"
    touch "$SOURCE_DIR/dir1/file4.txt"
    touch "$SOURCE_DIR/dir1/file5.log"
    touch "$SOURCE_DIR/dir1/subdir1/file6.txt"
    touch "$SOURCE_DIR/dir2/file7.txt"
    touch "$SOURCE_DIR/dir2/subdir2/file8.log"
    touch "$SOURCE_DIR/test_dir/file9.txt"
    touch "$SOURCE_DIR/test_dir/file10.log"
    touch "$SOURCE_DIR/logs/app.log"
    touch "$SOURCE_DIR/logs/error.log"
    touch "$SOURCE_DIR/cache/data.tmp"
    
    logInfo "Test files and directories created successfully"
}

# Test file extension pattern (*.log)
test_file_extension_pattern() {
    test_init "File extension pattern (*.log)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("*.log")
    
    # Debug: Show the test directory structure
    echo "DEBUG: Test directory structure:"
    find "$SOURCE_DIR" -name "*.log" | sort
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Debug: Show excluded files
    echo "DEBUG: Excluded files (${#EXCLUDED_FILES[@]}):"
    for file in "${EXCLUDED_FILES[@]}"; do
        echo "  - $file"
    done
    
    # Verify results
    local expected_files=6
    assertEquals "$expected_files" "${#EXCLUDED_FILES[@]}" "Should exclude $expected_files log files"
    
    # Check specific files
    local found_file2=0
    local found_file5=0
    local found_file8=0
    local found_file10=0
    local found_app_log=0
    local found_error_log=0
    
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$SOURCE_DIR/file2.log" ]]; then
            found_file2=1
        elif [[ "$file" == "$SOURCE_DIR/dir1/file5.log" ]]; then
            found_file5=1
        elif [[ "$file" == "$SOURCE_DIR/dir2/subdir2/file8.log" ]]; then
            found_file8=1
        elif [[ "$file" == "$SOURCE_DIR/test_dir/file10.log" ]]; then
            found_file10=1
        elif [[ "$file" == "$SOURCE_DIR/logs/app.log" ]]; then
            found_app_log=1
        elif [[ "$file" == "$SOURCE_DIR/logs/error.log" ]]; then
            found_error_log=1
        fi
    done
    
    assert "[ $found_file2 -eq 1 ]" "Should exclude file2.log"
    assert "[ $found_file5 -eq 1 ]" "Should exclude file5.log"
    assert "[ $found_file8 -eq 1 ]" "Should exclude file8.log"
    assert "[ $found_file10 -eq 1 ]" "Should exclude file10.log"
    assert "[ $found_app_log -eq 1 ]" "Should exclude app.log"
    assert "[ $found_error_log -eq 1 ]" "Should exclude error.log"
    
    # Verify no directories were excluded
    assertEquals "0" "${#EXCLUDED_DIRS[@]}" "No directories should be excluded"
    
    test_finish
}

# Test directory pattern (test_dir)
test_directory_pattern() {
    test_init "Directory pattern (test_dir)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("test_dir")
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results
    assertEquals "1" "${#EXCLUDED_DIRS[@]}" "Should exclude 1 directory"
    assertEquals "2" "${#EXCLUDED_FILES[@]}" "Should exclude 2 files within the directory"
    
    # Check specific directory
    assert "[ \"${EXCLUDED_DIRS[0]}\" == \"$SOURCE_DIR/test_dir\" ]" "Should exclude test_dir directory"
    
    # Check specific files
    local found_file9=0
    local found_file10=0
    
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$SOURCE_DIR/test_dir/file9.txt" ]]; then
            found_file9=1
        elif [[ "$file" == "$SOURCE_DIR/test_dir/file10.log" ]]; then
            found_file10=1
        fi
    done
    
    assert "[ $found_file9 -eq 1 ]" "Should exclude file9.txt within test_dir"
    assert "[ $found_file10 -eq 1 ]" "Should exclude file10.log within test_dir"
    
    # Verify FIND_EXCLUDE_OPTS contains the correct pattern
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"test_dir\"" "FIND_EXCLUDE_OPTS should contain test_dir pattern"
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"test_dir/\\*\"" "FIND_EXCLUDE_OPTS should exclude files within test_dir"
    
    test_finish
}

# Test multiple patterns
test_multiple_patterns() {
    test_init "Multiple patterns (*.tmp, logs, dir1/subdir1)"
    
    # Create an array with the test patterns
    declare -a EXCLUDE_PATTERNS=("*.tmp" "logs" "dir1/subdir1")
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results for *.tmp pattern
    local tmp_files=0
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == *".tmp" ]]; then
            tmp_files=$((tmp_files + 1))
        fi
    done
    
    assertEquals "2" "$tmp_files" "Should exclude 2 tmp files"
    
    # Verify results for logs directory
    local logs_dir_found=0
    for dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ "$dir" == "$SOURCE_DIR/logs" ]]; then
            logs_dir_found=1
            break
        fi
    done
    
    assert "[ $logs_dir_found -eq 1 ]" "Should exclude logs directory"
    
    # Verify results for dir1/subdir1 pattern
    local subdir1_found=0
    for dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ "$dir" == "$SOURCE_DIR/dir1/subdir1" ]]; then
            subdir1_found=1
            break
        fi
    done
    
    assert "[ $subdir1_found -eq 1 ]" "Should exclude dir1/subdir1 directory"
    
    # Verify FIND_EXCLUDE_OPTS contains all patterns
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"\\.tmp\"" "FIND_EXCLUDE_OPTS should contain *.tmp pattern"
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"logs\"" "FIND_EXCLUDE_OPTS should contain logs pattern"
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"dir1/subdir1\"" "FIND_EXCLUDE_OPTS should contain dir1/subdir1 pattern"
    
    test_finish
}

# Test double-asterisk pattern
test_double_asterisk_pattern() {
    test_init "Double-asterisk pattern (**/subdir*)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("**/subdir*")
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results
    assert "[ ${#EXCLUDED_DIRS[@]} -ge 2 ]" "Should exclude at least 2 directories"
    
    # Check specific directories
    local found_subdir1=0
    local found_subdir2=0
    
    for dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ "$dir" == "$SOURCE_DIR/dir1/subdir1" ]]; then
            found_subdir1=1
        elif [[ "$dir" == "$SOURCE_DIR/dir2/subdir2" ]]; then
            found_subdir2=1
        fi
    done
    
    assert "[ $found_subdir1 -eq 1 ]" "Should exclude dir1/subdir1"
    assert "[ $found_subdir2 -eq 1 ]" "Should exclude dir2/subdir2"
    
    # Verify files in subdirectories are excluded
    local found_file6=0
    local found_file8=0
    
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$SOURCE_DIR/dir1/subdir1/file6.txt" ]]; then
            found_file6=1
        elif [[ "$file" == "$SOURCE_DIR/dir2/subdir2/file8.log" ]]; then
            found_file8=1
        fi
    done
    
    assert "[ $found_file6 -eq 1 ]" "Should exclude file6.txt within subdir1"
    assert "[ $found_file8 -eq 1 ]" "Should exclude file8.log within subdir2"
    
    # Verify FIND_EXCLUDE_OPTS contains the correct pattern
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"subdir\"" "FIND_EXCLUDE_OPTS should contain subdir pattern"
    
    test_finish
}

# Test pattern with exact path
test_exact_path_pattern() {
    test_init "Exact path pattern (dir1/file4.txt)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("dir1/file4.txt")
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results
    assertEquals "0" "${#EXCLUDED_DIRS[@]}" "Should not exclude any directories"
    assertEquals "1" "${#EXCLUDED_FILES[@]}" "Should exclude exactly 1 file"
    
    # Check the specific file
    assert "[ \"${EXCLUDED_FILES[0]}\" == \"$SOURCE_DIR/dir1/file4.txt\" ]" "Should exclude dir1/file4.txt"
    
    # Verify FIND_EXCLUDE_OPTS contains the correct pattern
    assert "echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"dir1/file4.txt\"" "FIND_EXCLUDE_OPTS should contain dir1/file4.txt pattern"
    
    test_finish
}

# Test pattern with trailing slash (directory only)
test_trailing_slash_pattern() {
    test_init "Trailing slash pattern (logs/)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("logs/")
    
    # Debug: Show the test directory structure
    echo "DEBUG: Test directory structure:"
    find "$SOURCE_DIR" -type d | sort
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Debug: Show excluded directories
    echo "DEBUG: Excluded directories (${#EXCLUDED_DIRS[@]}):"
    for dir in "${EXCLUDED_DIRS[@]}"; do
        # Debug: Show each character in the directory path
        echo -n "  - '$dir' (chars: "
        for ((i=0; i<${#dir}; i++)); do
            char="${dir:$i:1}"
            if [[ "$char" == "/" ]]; then
                echo -n "/"
            else
                echo -n "$char"
            fi
        done
        echo ")"
    done
    
    # Debug: Show PATTERN_DIRS
    echo "DEBUG: PATTERN_DIRS:"
    for pattern in "${!PATTERN_DIRS[@]}"; do
        echo "  - Pattern: '$pattern', Dirs: '${PATTERN_DIRS[$pattern]}'"
    done
    
    # Debug: Show excluded files
    echo "DEBUG: Excluded files (${#EXCLUDED_FILES[@]}):"
    for file in "${EXCLUDED_FILES[@]}"; do
        echo "  - $file"
    done
    
    # Verify results
    assertEquals "1" "${#EXCLUDED_DIRS[@]}" "Should exclude 1 directory"
    
    # Debug: Show exact values being compared
    echo "DEBUG: Actual value: '${EXCLUDED_DIRS[0]}'"
    echo "DEBUG: Expected value: '$SOURCE_DIR/logs'"
    
    # Check the specific directory (removing trailing slash if present)
    dir_without_slash="${EXCLUDED_DIRS[0]%/}"
    assert "[ \"$dir_without_slash\" == \"$SOURCE_DIR/logs\" ]" "Should exclude logs directory"
    
    # Verify files in the logs directory are excluded
    local found_app_log=0
    local found_error_log=0
    
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$SOURCE_DIR/logs/app.log" ]]; then
            found_app_log=1
        elif [[ "$file" == "$SOURCE_DIR/logs/error.log" ]]; then
            found_error_log=1
        fi
    done
    
    assert "[ $found_app_log -eq 1 ]" "Should exclude app.log within logs directory"
    assert "[ $found_error_log -eq 1 ]" "Should exclude error.log within logs directory"
    
    test_finish
}

# Test pattern with wildcard in middle
test_middle_wildcard_pattern() {
    test_init "Middle wildcard pattern (file*.txt)"
    
    # Create an array with the test pattern
    declare -a EXCLUDE_PATTERNS=("file*.txt")
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results
    assertEquals "0" "${#EXCLUDED_DIRS[@]}" "Should not exclude any directories"
    
    # Count matching files
    local txt_files=0
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" =~ /file[0-9]*.txt$ ]]; then
            txt_files=$((txt_files + 1))
        fi
    done
    
    assert "[ $txt_files -ge 3 ]" "Should exclude at least 3 .txt files matching file*.txt"
    
    # Check specific files
    local found_file1=0
    local found_file4=0
    local found_file6=0
    local found_file9=0
    
    for file in "${EXCLUDED_FILES[@]}"; do
        if [[ "$file" == "$SOURCE_DIR/file1.txt" ]]; then
            found_file1=1
        elif [[ "$file" == "$SOURCE_DIR/dir1/file4.txt" ]]; then
            found_file4=1
        elif [[ "$file" == "$SOURCE_DIR/dir1/subdir1/file6.txt" ]]; then
            found_file6=1
        elif [[ "$file" == "$SOURCE_DIR/test_dir/file9.txt" ]]; then
            found_file9=1
        fi
    done
    
    assert "[ $found_file1 -eq 1 ]" "Should exclude file1.txt"
    assert "[ $found_file4 -eq 1 ]" "Should exclude file4.txt"
    assert "[ $found_file6 -eq 1 ]" "Should exclude file6.txt"
    assert "[ $found_file9 -eq 1 ]" "Should exclude file9.txt"
    
    test_finish
}

# Test empty patterns array
test_empty_patterns() {
    test_init "Empty patterns array"
    
    # Create an empty array
    declare -a EXCLUDE_PATTERNS=()
    
    # Run the pattern matcher
    generate_exclude_matches "$SOURCE_DIR" EXCLUDE_PATTERNS
    
    # Verify results
    assertEquals "0" "${#EXCLUDED_DIRS[@]}" "Should not exclude any directories"
    assertEquals "0" "${#EXCLUDED_FILES[@]}" "Should not exclude any files"
    
    # Verify FIND_EXCLUDE_OPTS is empty or contains only basic options
    assert "[ -z \"$FIND_EXCLUDE_OPTS\" ] || ! echo \"$FIND_EXCLUDE_OPTS\" | grep -q \"-path\"" "FIND_EXCLUDE_OPTS should not contain any path exclusions"
    
    test_finish
}

# Clean up after test
teardown() {
    logInfo "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
    logInfo "Teardown complete"
}

# Run all tests
run_tests() {
    # Set up test environment
    setup || return 1
    
    # Run test cases
    test_file_extension_pattern
    test_directory_pattern
    test_multiple_patterns
    test_double_asterisk_pattern
    test_exact_path_pattern
    test_trailing_slash_pattern
    test_middle_wildcard_pattern
    test_empty_patterns
    
    # Clean up
    teardown
    
    # Print test summary
    print_test_summary
}

# Call the run_tests function to execute all tests
run_tests
