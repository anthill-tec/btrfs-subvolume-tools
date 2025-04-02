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

```
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

```
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
