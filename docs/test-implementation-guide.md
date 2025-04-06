# Implementation Guide for using Trishul Frameworks testing capabilities

This guide explains how to implement the test-utils.sh framework in your Command Tools project. The framework provides a structured approach to testing with better logging, command execution control, and assertion capabilities.

## Overview of Changes

The updated test scripts use the following key features from the test-utils.sh framework:

1. **Logging functions** for different visibility levels:
   - `logDebug`: Only shown in DEBUG mode
   - `logInfo`, `logWarn`, `logError`: Always shown

2. **Command execution** with controlled output:
   - `execCmd`: Runs commands while managing their output visibility

3. **Assertions** for validating test conditions:
   - `assert`: Basic condition checking
   - `assertEquals`: Value comparison
   - `assertFileExists`: File existence checking

4. **Test lifecycle management** (handled by the test runner):
   - `test_init`: Called by the test runner to initialize a test
   - `test_finish`: Called by the test runner to finalize a test

## Implementation Steps

### 1. Ensure that the Test Framework is available

Ensure that the test-utils.sh framework is available in the project. If not, you can add it by following these steps:

1. Clone the test-utils repository from <https://github.com/trishul-tool-builder/trishul-builder.git>
2. Ensure that the test-utils.sh, test-runner.sh, global-hooks.sh,test-orchestrator.sh and test-bootstrap.sh  are available in your project's tests directory.

### 2. Create your test scripts

Create your test scripts in the tests directory. The scripts should be named like 01-test-create-subvolume.sh and 02-test-configure-snapshots.sh. The pattern is NN-test-\<suite\>.sh where NN is a number that determines execution order (e.g., 01, 02, 10) and suite is a brief identifier of the command script that is being tested. The NN order helps in reporting of test results.

### 3. Update Test Scripts

For each test script (should be named like 01-test-create-subvolume.sh and 02-test-configure-snapshots.sh), make the following changes:

1. Remove any legacy output methods (echo statements)
2. Replace command execution with `execCmd`
3. Add assertions to validate test conditions
4. Use logging functions to document test steps

For example, replace:

```bash
echo "Running test: Default configuration with backup flag"
    
# Prepare test data
prepare_test_data || return 1
    
# Run the script with minimal arguments...
"$SCRIPT_PATH" --target-device "$TARGET_DEVICE" ...
```

With:

```bash
logInfo "Running test: Default configuration with backup flag"
    
# Prepare test data
prepare_test_data
assert "[ $? -eq 0 ]" "Test data preparation should succeed"
    
# Run the script with minimal arguments
execCmd "Running create-subvolume script" "\"$SCRIPT_PATH\" \
    --target-device \"$TARGET_DEVICE\" ..."
```

### 4. Update Helper Functions

Update any helper functions to use the framework features. For example:

```bash
# Before:
prepare_subvolume() {
    echo "Creating test subvolume..."
    
    # Mount target device
    mount "$TARGET_DEVICE" "$TARGET_MOUNT" || return 1
    
    # Create the subvolume...
    
    echo "✓ Test subvolume created successfully"
    return 0
}

# After:
prepare_subvolume() {
    logInfo "Creating test subvolume..."
    
    # Mount target device
    execCmd "Mount target device" "mount \"$TARGET_DEVICE\" \"$TARGET_MOUNT\""
    assert "[ $? -eq 0 ]" "Target device should mount successfully"
    
    # Create the subvolume...
    
    logInfo "✓ Test subvolume created successfully"
    return 0
}
```

### 5. Update Setup and Teardown

Update the setup and teardown functions to use logging and command execution control:

```bash
setup() {
    # Use the global temp directory provided by setup_all.sh
    logDebug "Setting up test environment"
    TEST_DIR="$TEST_TEMP_DIR/create-subvolume-test"
    execCmd "Create test directory" "mkdir -p \"$TEST_DIR\""
    
    # More setup code...
    
    return 0
}

teardown() {
    logDebug "Cleaning up test environment"
    
    # Cleanup code...
    
    logDebug "Cleanup completed"
    return 0
}
```

## Running Tests

Tests can be run in two modes:

- **Normal mode** (default): Shows INFO, WARN, ERROR logs and test results

  ```bash
  sudo make test
  ```

- **Debug mode**: Shows all logs (including DEBUG) and command outputs

  ```bash
  sudo make debug-test
  ```

## Benefits

1. **Consistent Output**: Standard format for logs and test results
2. **Controlled Visibility**: Show only what's needed based on DEBUG_MODE
3. **Better Diagnostics**: Clear assertions and detailed failure reporting
4. **Easier Maintenance**: Centralized logging and command execution
5. **Cleaner Code**: Separation of logging, assertion, and execution logic

## Example Test Output

In normal mode:

```bash
▶ TEST: default_config
[INFO] Running test: Default configuration
[INFO] Creating test subvolume...
[INFO] ✓ Test subvolume @home created successfully
[INFO] Configuring snapper with default options
[INFO] ✓ Snapper configuration was created successfully
[INFO] ✓ Timeline settings properly configured
[INFO] Creating test snapshot
[INFO] ✓ Successfully created a test snapshot
[INFO] ✓ Successfully verified snapshot creation
✓ TEST PASSED: default_config (5 assertions)
```

In debug mode:

```bash
============================================
  TEST: default_config
============================================
[DEBUG] Setting up test environment
[INFO] Running test: Default configuration
[DEBUG] Executing: Format device
[DEBUG] Command: mkfs.btrfs -f "/dev/loop8"
...
```

## Conclusion

By implementing this framework, you'll have better control over your test output, making it easier to diagnose issues and understand test results. The separation of execution, logging, and assertions creates a more maintainable testing system.

## Advanced Testing Insights and Best Practices

### Separation of Production and Test Code

1. **Avoid Hardcoded Test Logic in Production Code**
   - Keep test-specific logic out of production code
   - Production code should not contain references to specific test files or test data
   - Use configuration and parameters instead of hardcoding test-specific values

2. **Proper Debug Logging**
   - Implement a debug mode that can be enabled via command-line flags
   - Debug logs should provide useful information without exposing sensitive data
   - Use structured logging with clear categories (e.g., [DEBUG], [INFO], [ERROR])
   - For pattern matching or complex logic, add detailed debug logs that explain the decision process

### Pattern Matching and Exclusion Testing

1. **Testing Pattern Matching Logic**
   - Create test cases with various pattern formats (glob patterns, path patterns, etc.)
   - Include edge cases like patterns with special characters, nested directories, etc.
   - Test both inclusion and exclusion patterns
   - Verify that patterns work correctly with paths containing spaces or special characters

2. **Double-Asterisk Pattern Testing**
   - Specifically test `**/` patterns which match at any directory depth
   - Ensure patterns like `**/tmp/` correctly match both `/tmp/` and `/path/to/tmp/`
   - Verify that patterns don't inadvertently match partial directory names (e.g., `**/log/` shouldn't match `/catalog/`)

3. **Directory vs. File Pattern Testing**
   - Test patterns with and without trailing slashes to ensure correct behavior
   - Verify that directory patterns only match directories and not files with similar names
   - Test patterns that should match both files and directories

### Methodical Debugging Approach

1. **Systematic Problem Identification**
   - Never make quick assumptions about the root cause
   - Thoroughly examine both the System Under Test (SUT) and the test framework
   - Consider all possible reasons for failure before making code changes
   - Use proper debugging tools and techniques to isolate the actual problem

2. **Debugging Workflow**
   - Start with enabling debug mode to get more detailed logs
   - Add temporary debug statements to track the flow of execution
   - Use controlled test cases that isolate the specific behavior you're debugging
   - Compare expected vs. actual behavior at each step

3. **Incremental Verification**
   - After making changes, verify each component individually
   - Test simple cases first, then move to more complex scenarios
   - Use debug logging to confirm that your changes are having the intended effect
   - Verify that fixing one issue doesn't introduce regressions elsewhere

### Test Naming and Organization

1. **Consistent Test Naming**
   - Test files should follow the pattern: `NN-test-<suite>.sh` where NN is a number for execution order
   - Test functions should follow the pattern: `test_<descriptive_name>()`
   - When running tests, use the base name without the NN-test- prefix and .sh extension
   - Test case names should be descriptive and indicate what's being tested

2. **Test Organization**
   - Group related tests within the same test file
   - Order tests from simple to complex
   - Include setup and teardown functions to ensure clean test environments
   - Use helper functions to avoid code duplication across tests

### Test Execution and Automation

1. **Non-Interactive Testing**
   - Always provide a non-interactive mode for automated testing
   - Ensure tests can run without user input in CI/CD environments
   - Use appropriate default values when running in non-interactive mode
   - Document which tests require special environment setup

2. **Test Isolation**
   - Each test should be independent and not rely on the state from previous tests
   - Use temporary directories and files that are cleaned up after each test
   - Reset global state between tests to prevent cross-test contamination
   - Consider using containerization for complete isolation

3. **Error Handling in Tests**
   - Tests should fail fast and with clear error messages
   - Capture and log all relevant information when a test fails
   - Include context about the expected vs. actual behavior
   - Provide guidance on how to reproduce and fix the issue

By following these advanced testing practices, you'll create more robust, maintainable, and effective tests that can catch issues early and provide clear guidance when problems occur.
