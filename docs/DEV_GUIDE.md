# Bash Project Developer Guide

This comprehensive guide covers the development workflow, build system, and testing framework for Bash script-based tool projects.

## Table of Contents

1. [Overview](#overview)
2. [Directory Structure](#directory-structure)
3. [Development Workflow](#development-workflow)
   - [Setting Up](#setting-up)
   - [Build System](#build-system)
   - [Running Tests](#running-tests)
   - [Development Installation](#development-installation)
4. [Deployment Workflow](#deployment-workflow)
   - [Package Creation](#package-creation)
   - [Distribution-Specific Packages](#distribution-specific-packages)
5. [Testing Framework](#testing-framework)
   - [Quick Start](#quick-start)
   - [Writing Tests](#writing-tests)
   - [Test Organization](#test-organization)
   - [Test Execution](#test-execution)
   - [Advanced Testing](#advanced-testing)
6. [Makefile Reference](#makefile-reference)
7. [Environment Variables](#environment-variables)
8. [Troubleshooting](#troubleshooting)

## Overview

This framework provides a structured approach to developing Bash script-based tools with a focus on:

- Clean, maintainable code
- Comprehensive testing
- Cross-distribution compatibility
- Proper logging and error handling

This developer guide covers both the build system for development and deployment, and the testing framework for ensuring code quality.

## Directory Structure

```bash
project-root/
├── bin/                  # Executable scripts
├── docs/                 # Documentation
│   ├── DEV_GUIDE.md      # This developer guide
│   └── *.md              # Man page sources and other documentation
├── .dist/                # Build and packaging output directory
│   ├── arch/             # Arch Linux packaging
│   ├── debian/           # Debian packaging
│   └── *.tar.gz          # Source tarballs for packaging
├── tests/                # Test framework and test cases
│   ├── logs/             # Test logs directory
│   ├── test-*.sh         # Test suite files
│   └── framework/        # Test framework scripts (RESERVED)
├── Makefile              # Main build system interface
├── install.sh            # Installation script
└── logging.sh            # Logging utilities
```

**Note about test framework:**

- The test framework provides a structured approach to testing Bash scripts
- Only create or modify test suite files (test-*.sh)
- The framework scripts in tests/framework/ should not be modified
- This architecture is designed to be reusable across multiple projects

## Development Workflow

### Setting Up

1. Clone the repository:

   ```bash
   git clone https://github.com/username/project-name.git
   cd project-name
   ```

2. Check dependencies:

   ```bash
   make check-deps
   ```

### Build System

The build system is implemented through a Makefile that provides targets for both development and deployment. To see all available targets:

```bash
make help
```

### Running Tests

The project includes a comprehensive test framework that can be invoked through the Makefile:

```bash
# Run all tests
sudo make test

# Run tests with debug output
sudo make debug-test

# Run specific test suite
sudo make test test-suite=suite-name

# Run specific test case
sudo make test test-suite=suite-name test-case=case-name

# Clean up test environment
make test-clean
```

Note that some tests may require root privileges depending on the operations they perform.

### Development Installation

For development and testing, you can install directly:

```bash
# Generate man pages
make man

# Install to default location (/usr/local)
sudo make install

# Install to custom location
sudo make install PREFIX=/opt/tools

# Uninstall
sudo make uninstall
```

## Deployment Workflow

For production deployments, the recommended approach is to use the package-based installation.

### Package Creation

The build system can automatically detect your distribution and create the appropriate package:

```bash
# Create package for detected system
make pkg

# Generate packaging files only
make pkg-files

# Create source tarball for packaging
make dist
```

### Distribution-Specific Packages

#### Arch Linux

```bash
# Build an Arch Linux package
make pkg-arch

# Install the built package
sudo pacman -U .dist/arch/*.pkg.tar.zst
```

#### Debian-based Systems

```bash
# Build a Debian package
make pkg-deb

# Install the built package
sudo dpkg -i .dist/*.deb
```

The build system supports cross-distribution package building, allowing you to:


- Build Debian packages on Arch-based systems (and vice versa)
- Create consistent package structures across different distributions
- Use a fallback mechanism when full build dependencies aren't available

This makes the framework more portable and easier to deploy across different Linux distributions.

## Testing Framework

The project uses a lightweight, reusable testing framework for Bash scripts. It provides a structured approach to writing and running tests with proper logging, assertions, and test lifecycle management.

For detailed implementation information, see the test framework documentation in the docs directory.

### Quick Start

```bash
# Run all tests
sudo make test

# Run a specific test suite
sudo make test test-suite=suite-name

# Run a specific test case
sudo make test test-suite=suite-name test-case=case-name

# Debug mode for detailed output
sudo make debug-test
```

### Writing Tests

#### Creating a Test File

Create a file in the `tests/` directory with a name following the pattern `test-description.sh`:

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

#### Available Assertions

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

### Test Organization

#### Naming Conventions

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
02-test-feature-one.sh
10-test-feature-two.sh
```

When referring to test suites with the `--test-suite` option, you can use any of these formats:

```bash
# Full name
sudo make test test-suite=02-test-feature-one.sh

# Without extension
sudo make test test-suite=02-test-feature-one

# Without numeric prefix
sudo make test test-suite=feature-one
```

#### Test Case Naming

Test functions should follow this naming pattern:

```bash
test_description
```

Where `description` describes what aspect is being tested.

Examples:

```bash
test_default_behavior()
test_custom_options()
test_error_handling()
```

When referring to test cases with the `--test-case` option, you can use either:

```bash
# With prefix
sudo make test test-case=test_default_behavior

# Without prefix
sudo make test test-case=default_behavior
```

#### Global Hooks

The framework supports global hooks that run once before all tests and after all tests are complete:

```bash
# In tests/global-hooks.sh
global_setup() {
    echo "Setting up global test environment"
}

global_teardown() {
    echo "Cleaning up global test environment"
}
```

### Test Execution

#### Command Line Options

| Option | Description |
|--------|-------------|
| `test` | Run all tests |
| `debug-test` | Run all tests with detailed output |
| `test-suite=NAME` | Run a specific test suite |
| `test-case=NAME` | Run a specific test case |

Example:

```bash
sudo make test test-suite=feature-one test-case=default_behavior
```

### Advanced Testing

The testing framework provides several advanced features:

- **Logging levels**: Debug, info, warning, and error
- **Command execution control**: Run commands with controlled output visibility
- **Test lifecycle management**: Setup, test execution, and teardown
- **Assertion library**: Comprehensive set of assertion functions
- **Isolated test environment**: Tests run in a clean environment

## Makefile Reference

The Makefile provides targets for both development and deployment workflows:

### Development Targets

- `make all` - Generate man pages
- `make test` - Run tests (requires root)
- `make debug-test` - Run tests with debug output (requires root)
- `make test-clean` - Clean up test environment

### Installation Targets

- `make install` - Install directly (development mode)
- `make uninstall` - Uninstall direct installation

### Packaging Targets

- `make pkg` - Build package for detected system
- `make pkg-arch` - Build Arch Linux package
- `make pkg-deb` - Build Debian package
- `make pkg-files` - Generate packaging files
- `make dist` - Create source tarball for packaging

### Other Targets

- `make clean` - Remove generated files
- `make check-deps` - Check for dependencies
- `make man` - Generate man pages

## Environment Variables

The build system respects several environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `PREFIX` | Installation prefix | `/usr/local` |
| `DESTDIR` | Destination directory for staged installation | (empty) |
| `DEBUG` | Enable debug output | (unset) |
| `PROJECT_NAME` | Project name for logging | (project specific) |
| `MAINTAINER_NAME` | Package maintainer's name | `Antony John` |
| `MAINTAINER_EMAIL` | Package maintainer's email | `still.duck5711@fastmail.com` |
| `VERSION` | Package version | `1.0.0` |

Example usage:

```bash
# Install to a staging directory
make install DESTDIR=/tmp/stage PREFIX=/usr

# Enable debug output for tests
DEBUG=true sudo make test

# Build a package with custom maintainer information
make pkg-arch MAINTAINER_NAME="Your Name" MAINTAINER_EMAIL="your.email@example.com"
```

### Package Building Options

The build system provides flexible options for creating distribution packages:

#### Cross-Distribution Package Building

You can build packages for different distributions regardless of your host system:

```bash
# Build an Arch package on any system
make pkg-arch

# Build a Debian package on any system
make pkg-deb
```

The Debian package building includes a fallback mechanism that will create a simplified package when the full Debian build dependencies aren't available.

#### Customizing Package Metadata

You can customize various aspects of the package metadata:

```bash
# Custom version
make pkg VERSION=1.1.0

# Custom maintainer information
make pkg-arch MAINTAINER_NAME="Your Name" MAINTAINER_EMAIL="your.email@example.com"

# Combined options
make pkg-deb VERSION=1.1.0 MAINTAINER_NAME="Your Name" MAINTAINER_EMAIL="your.email@example.com"
```

#### Package Output Location

All built packages are placed in the `.dist` directory:

- Arch packages: `.dist/btrfs-subvolume-tools-<version>-<release>-any.pkg.tar.zst`
- Debian packages: `.dist/btrfs-subvolume-tools_<version>_all.deb`

## Troubleshooting

### Common Issues

1. **Missing Dependencies**

   If you encounter errors about missing dependencies, run:

   ```bash
   make check-deps
   ```

2. **Permission Errors**

   Some operations require root privileges. Make sure to use `sudo` when needed:

   ```bash
   sudo make test
   sudo make install
   ```

3. **Package Building Errors**

   If package building fails, ensure you have the required tools:
   
   For Arch Linux:

   ```bash
   sudo pacman -S base-devel
   ```
   
   For Debian:

   ```bash
   sudo apt install build-essential devscripts debhelper
   ```

4. **Test Failures**

   If tests fail, check the logs in the `tests/logs` directory for detailed information. You can also run tests in debug mode:

   ```bash
   sudo make debug-test
   ```

### Getting Help

If you encounter issues not covered here, please:

1. Check the output of `make help` for available targets
2. Review the logs in the `tests/logs` directory (for test failures)
3. File an issue on the project repository with detailed information about the problem

---

This documentation was last updated on March 30, 2025.
