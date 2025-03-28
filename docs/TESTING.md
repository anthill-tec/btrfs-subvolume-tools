# Bash Testing Framework User Manual

## Introduction

This is a lightweight, reusable testing framework for Bash scripts with built-in support for containerized testing. It provides a simple way to write and run tests for your Bash projects with minimal setup.

## Quick Start

```bash
# Run all tests
./install.sh --test

# Run a specific test
./install.sh --test-suite=configure-snapshots

# Run a specific test case
./install.sh --test-case=default_config

# Debug mode for detailed output
./install.sh --debug-test
```

## Writing Tests

### Creating a Test File

Create a file in the `tests/` directory with a name following the pattern `NN-test-description.sh`, where `NN` is a number for ordering:

```bash
#!/bin/bash
# Test file for feature X

# Optional setup function runs before tests
setup() {
    echo "Setting up test environment"
}

# Test functions start with test_
test_feature_works() {
    # Your test code here
    assert "[ 1 -eq 1 ]" "Basic assertion should pass"
}

# Optional teardown function runs after tests
teardown() {
    echo "Cleaning up test environment"
}
```

### Available Assertions

```bash
# Basic assertion
assert "[ $result -eq 0 ]" "Command should succeed"

# Check equality
assertEquals "$actual" "$expected" "Values should match"

# Check file existence
assertFileExists "/path/to/file" "File should exist"

# Check directory existence
assertDirExists "/path/to/dir" "Directory should exist"

# Run command and check success
assertCmd "grep -q 'pattern' file" "Pattern should be found in file"
```

## Test Organization

### Naming Conventions

Test files follow a specific naming pattern to control execution order:

```bash
NN-test-description.sh
```

Where:

- `NN` is a number that determines execution order (e.g., 01, 02, 10)
- `description` is a brief identifier of what's being tested

Examples:

```bash
01-test-basic-functions.sh
02-test-configure-snapshots.sh
10-test-snapshot-creation.sh
```

When referring to test suites with the `--test-suite` option, you can use any of these formats:

```bash
# Full name
./install.sh --test-suite=02-test-configure-snapshots.sh

# Without extension
./install.sh --test-suite=02-test-configure-snapshots

# Without numeric prefix
./install.sh --test-suite=configure-snapshots

# Without prefix and extension
./install.sh --test-suite=configure-snapshots
```

### Test Case Naming

Test functions should follow this naming pattern:

```bash
test_description
```

Where `description` describes what aspect is being tested.

Examples:

```bash
test_default_config()
test_custom_retention_policy()
test_invalid_input_handling()
```

When referring to test cases with the `--test-case` option, you can use either:

```bash
# With prefix
./install.sh --test-case=test_default_config

# Without prefix
./install.sh --test-case=default_config
```

### Global Hooks

The framework supports global hooks that run once before all tests and after all tests are complete. These are defined in a special file that is loaded by the test runner.

To use global hooks:

1. Create or edit the `tests/global-hooks.sh` file
2. Define the following functions:

```bash
# Runs once before any test suite is executed
global_setup() {
    echo "Setting up global test environment"
    # Create shared resources
    # Set up database
    # Configure global environment variables
}

# Runs once after all test suites have completed
global_teardown() {
    echo "Cleaning up global test environment"
    # Remove shared resources
    # Clean up database
    # Reset environment
}
```

Global hooks are ideal for:

- Setting up resources shared by multiple test suites
- Initializing databases or external services
- Creating test data used by multiple test suites
- Final cleanup after all tests have run

### Test Lifecycle

The complete test execution lifecycle is:

1. `global_setup` (if defined in global-hooks.sh)
2. For each test suite:
   a. `setup` (if defined in the test suite)
   b. Each test case in the suite
   c. `teardown` (if defined in the test suite)
3. `global_teardown` (if defined in global-hooks.sh)

## Running Tests

### Command Line Options

| Option | Description |
|--------|-------------|
| `--test` | Run all tests |
| `--debug-test` | Run all tests with detailed output |
| `--test-suite=NAME` | Run a specific test suite |
| `--test-case=NAME` | Run a specific test case |

### Flexible Naming

The framework supports flexible naming conventions:

- **Test Suites**: You can specify with or without the numeric prefix and `.sh` extension
  - Example: `--test-suite=configure-snapshots` will match `02-test-configure-snapshots.sh`

- **Test Cases**: You can specify with or without the `test_` prefix
  - Example: `--test-case=default_config` will match `test_default_config`

## Containerized Testing

This framework includes built-in support for running tests in isolated containers:

- Tests run in a clean environment
- No interference with the host system
- Consistent test results across different machines

## Tips and Tricks

1. **Debugging**: Use `--debug-test` to see detailed output
2. **Isolation**: Run a specific test case with `--test-case=NAME` to isolate issues
3. **Combining Options**: Use both `--test-suite` and `--test-case` for precise control

## Example Workflow

1. Write your test file in `tests/` directory
2. Run all tests: `./install.sh --test`
3. If a test fails, debug it: `./install.sh --debug-test --test-case=failing_test`
4. Fix the issue and run again

## Extending the Framework

To add custom assertions or utilities:

1. Add your functions to `tests/test-utils.sh`
2. Use them in your test files

## Conclusion

This testing framework provides a simple yet powerful way to test Bash scripts. With its containerized testing support, you can ensure your scripts work correctly in a clean environment.
