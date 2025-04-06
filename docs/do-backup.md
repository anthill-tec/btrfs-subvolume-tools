# do-backup.sh - BTRFS Backup Utility

## NAME

do-backup.sh - Create backups of directories for BTRFS subvolume operations

## SYNOPSIS

```bash
do-backup.sh [options]
```

## DESCRIPTION

The `do-backup.sh` script is a versatile backup utility designed to create backups of directories, primarily for use with BTRFS subvolume operations. It supports multiple backup methods and provides flexible error handling options.

The script automatically selects the most efficient backup method based on available system tools, with graceful fallback to simpler methods if dependencies are not met.

## OPTIONS

* `-h, --help`  
  Show help message and exit.

* `-s, --source DIR`  
  Source directory to backup (required).

* `-d, --destination DIR`  
  Destination directory for backup (required).

* `-m, --method METHOD`  
  Specify the method for copying data:
  * `tar`: Use tar with pv for compression and progress (requires: tar, pv)
  * `parallel`: Use GNU parallel for multi-threaded copying (requires: parallel)
  
  The script will automatically fall back to simpler methods if dependencies are not met.

* `-e, --error-handling MODE`  
  Specify how to handle file copy errors:
  * `strict`: Stop on first error (default)
  * `continue`: Skip problem files and continue

* `-n, --non-interactive`  
  Run without prompting for user input.

* `--debug`  
  Enable debug mode with detailed logging. This option provides verbose output about the backup process, including pattern matching details, file operations, and execution flow. Useful for troubleshooting exclude pattern issues or diagnosing backup failures.

* `--exclude=PATTERN`  
  Exclude files/directories matching PATTERN. This option can be specified multiple times to exclude different patterns.

* `--exclude-from=FILE`  
  Read exclude patterns from FILE (one pattern per line).

* `--show-excluded`  
  Interactively review and select which files and directories to exclude. This feature requires the `dialog` package to be installed. Note that this option is incompatible with `--non-interactive` mode and will cause the script to exit with an error if both are specified.

## EXCLUDE PATTERNS

The `do-backup.sh` script supports excluding files and directories from the backup using glob-style patterns. This is useful for skipping temporary files, logs, caches, or other files that don't need to be backed up.

There are two ways to specify exclude patterns:

1. Using the `--exclude=PATTERN` option (can be specified multiple times)
2. Using the `--exclude-from=FILE` option to read patterns from a file (one pattern per line)

### Pattern Format

The script supports several types of exclusion patterns:

* **Double-asterisk patterns** (`**/pattern` or `pattern/**`):
  * `**/pattern` matches files/directories with the name "pattern" at any level in the directory tree
  * `pattern/**` matches all files and directories under a directory named "pattern"
  * Example: `dist/**` excludes the entire `dist` directory and all its contents

* **Hidden file/directory patterns** (`.pattern`):
  * Matches hidden files or directories starting with a dot
  * Example: `.git` excludes all files/directories named ".git"

* **Directory patterns with trailing slashes** (`dir/`):
  * Specifically matches directories (not files) with the given name
  * Example: `cache/` excludes directories named "cache" but not files named "cache"

* **Path patterns with slashes** (`dir/file`):
  * Patterns containing slashes are matched against the full path relative to the source directory
  * Example: `logs/debug.log` only excludes "debug.log" in the "logs" directory

* **File extension patterns** (`*.ext`):
  * Matches files with the specified extension
  * Example: `*.tmp` excludes all files with the ".tmp" extension

* **Regular patterns** (anything else):
  * Matches files or directories by name anywhere in the directory tree
  * Example: `node_modules` excludes all files and directories named "node_modules"

### Pattern Behavior

* Patterns without slashes match anywhere in the path
* Patterns with slashes are matched against the path relative to the source root
* Comments in exclude files start with `#` and are ignored
* Empty lines in exclude files are ignored
* When a directory is excluded, all its contents are also excluded
* Patterns are case-sensitive on Unix/Linux systems

### Interactive Exclude Selection

You can use the `--show-excluded` option to interactively review and select which files and directories to exclude. This feature requires the `dialog` package to be installed.

**Important**: The `--show-excluded` option is incompatible with `--non-interactive` mode. If both options are specified, the script will display an error message and exit with a failure status.

When using this option, the script provides a two-level selection interface:

1. **Pattern Level**: First, you'll see a checklist of all exclude patterns with counts of matching files/directories. You can select which patterns you want to apply.

2. **File/Directory Level**: For each selected pattern, you'll then see a checklist of the specific files and directories matched by that pattern. You can select which specific items you want to exclude.

This hierarchical approach gives you fine-grained control over what gets excluded from your backup.

#### Interactive UI Examples

**Pattern Selection Screen:**

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Exclude Patterns                                                        │
│                                                                         │
│ Select patterns to exclude (Space to toggle, Enter to confirm):         │
│                                                                         │
│    [X] *.log (15 files)                                                 │
│    [X] *.tmp (8 files)                                                  │
│    [X] cache/ (2 dirs, 42 files)                                        │
│    [X] node_modules/ (5 dirs, 230 files)                                │
│    [ ] *.bak (no matches)                                               │
│                                                                         │
│                                                                         │
│                                                                         │
│                                                                         │
│                     <OK>                     <Cancel>                    │
└────────────────────────────────────────────────────────────────────────┘
```

**File/Directory Selection Screen (for a specific pattern):**

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Files/Directories for Pattern: *.log                                    │
│                                                                         │
│ Select items to exclude (Space to toggle, Enter to confirm):            │
│                                                                         │
│    [X] /home/user/project/logs/app.log                                  │
│    [X] /home/user/project/logs/error.log                                │
│    [ ] /home/user/project/logs/debug.log                                │
│    [X] /home/user/project/src/output.log                                │
│    [X] /home/user/project/tmp/build.log                                 │
│                                                                         │
│                                                                         │
│                                                                         │
│                     <OK>                     <Cancel>                   │
└────────────────────────────────────────────────────────────────────────┘
```

**Exclusion Summary Screen:**

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Exclude Summary                                                         │
│                                                                         │
│ The backup will exclude:                                                │
│                                                                         │
│ - 7 directories                                                         │
│ - 289 files                                                             │
│                                                                         │
│ Selected patterns will be applied to the backup process.                │
│                                                                         │
│                                                                         │
│                               <OK>                                      │
└────────────────────────────────────────────────────────────────────────┘
```

#### UI Navigation Tips

* Use **arrow keys** to navigate between items
* Press **Space** to toggle selection of an item
* Press **Enter** to confirm your selections and proceed
* Press **Tab** to move between the list and the buttons
* Press **Esc** to cancel the current dialog

### Examples

```bash
# Basic exclusion examples
do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.log' --exclude='tmp/'

# Read exclude patterns from a file
do-backup.sh -s /home/user -d /mnt/backup/home --exclude-from=exclude_patterns.txt

# Interactively select which files and directories to exclude
do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.log' --exclude='tmp/' --show-excluded

# Example exclude_patterns.txt file content:
# *.log
# *.tmp
# cache/
# node_modules/
# .git/
```

#### More Comprehensive Examples

```bash
# Exclude specific directories and their contents
do-backup.sh -s /home/user/project -d /mnt/backup/project --exclude='node_modules/**' --exclude='dist/**'

# Exclude hidden directories (common in development projects)
do-backup.sh -s /home/user/project -d /mnt/backup/project --exclude='.git' --exclude='.vscode' --exclude='.idea'

# Exclude temporary and build artifacts
do-backup.sh -s /home/user/project -d /mnt/backup/project --exclude='*.o' --exclude='*.a' --exclude='*.so' --exclude='*.pyc'

# Exclude log directories at any level in the directory tree
do-backup.sh -s /home/user/project -d /mnt/backup/project --exclude='**/logs' --exclude='**/log'

# Exclude specific files in specific directories
do-backup.sh -s /home/user/project -d /mnt/backup/project --exclude='config/secrets.json' --exclude='data/large_dataset.csv'

# Combine multiple pattern types
do-backup.sh -s /home/user/project -d /mnt/backup/project \
  --exclude='*.log' \
  --exclude='tmp/' \
  --exclude='node_modules/**' \
  --exclude='.git' \
  --exclude='build/temp/**' \
  --exclude='**/cache'
```

#### Example exclude_patterns.txt for a Development Project

```
# Temporary files
*.tmp
*.temp
*.swp
*~

# Build artifacts
*.o
*.a
*.so
*.pyc
*.class
*.jar
*.war
__pycache__/
*.egg-info/

# Build directories
build/
dist/
target/
out/

# Development environment
.git/
.svn/
.hg/
.idea/
.vscode/
.settings/
.project
.classpath

# Dependencies
node_modules/
vendor/
bower_components/
jspm_packages/

# Logs and caches
logs/
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.npm/
.yarn/
.cache/

# Large data files
*.csv
*.sqlite
*.db
```

#### Troubleshooting Common Issues

##### Exclude File Not Found

If you see "Warning: Exclude file not found" errors:

1. **Check file path and permissions**:
   ```bash
   ls -la /path/to/your/exclude/file
   ```

2. **When using sudo**:
   * The tilde (`~`) in paths refers to root's home directory, not your user's
   * Use `$HOME` variable or absolute paths instead:
   ```bash
   sudo do-backup.sh --exclude-from=$HOME/.backupIgnore
   # or
   sudo do-backup.sh --exclude-from=/home/username/.backupIgnore
   ```

3. **Avoid quotes around paths with tilde**:
   * Correct: `--exclude-from=~/.backupIgnore`
   * Incorrect: `--exclude-from='~/.backupIgnore'`

##### Dialog Not Showing

If the interactive exclude selection dialog doesn't appear:

1. **Verify dialog is installed**:
   ```bash
   # For Arch Linux
   pacman -Q dialog
   ```

2. **Environment issues with sudo**:
   * When running with sudo, the dialog may fail to display due to environment variables
   * Try using `sudo -E` to preserve your environment variables:
   ```bash
   sudo -E create-subvolume [other options]
   ```
   
3. **Terminal type issues**:
   * Set the TERM environment variable explicitly:
   ```bash
   TERM=xterm sudo create-subvolume [other options]
   ```

4. **X11 forwarding issues**:
   * If running over SSH, ensure X11 forwarding is enabled
   * Try using a text-based dialog alternative by setting:
   ```bash
   export DIALOGRC=/path/to/dialogrc
   ```

##### Pattern Matching Issues

If the script reports "Analysis complete. Found X directories and Y files matching patterns" but then shows "No matches found for pattern":

1. **Check for path relativity issues**:
   * The script may be using absolute paths internally but comparing with relative paths
   * Try patterns without leading slashes
   * For debugging, you can add a simple pattern that you know exists (like a specific filename)

2. **Large number of matches**:
   * If there are too many matches (thousands of files), the dialog may fail to display
   * Try with a more specific pattern that matches fewer files

## BACKUP METHODS

The script supports several backup methods, automatically selecting the best available based on installed tools:

1. **tar** - Uses tar with pv for compression and progress tracking. This method is efficient for backing up large directories with many small files.

2. **parallel** - Uses GNU parallel for multi-threaded copying, which can significantly improve performance on systems with multiple CPU cores.

3. **cp-progress** - Falls back to this method if tar/pv is not available. Uses the 'progress' tool to show copy progress.

4. **cp-plain** - The simplest fallback method, uses standard cp command without progress indication.

## ERROR HANDLING

The script provides two error handling modes:

1. **strict** (default) - Stops on the first error encountered during backup.

2. **continue** - Skips problem files and continues with the backup. At the end, it provides a summary of failed files.

## INTERRUPTION HANDLING

The script handles user interruptions (Ctrl+C) gracefully:

1. In interactive mode, it asks if you want to continue despite the interruption.
2. In non-interactive mode, it cleanly terminates the backup operation.

## EXIT CODES

* `0` - Backup completed successfully
* `1` - Error occurred (invalid arguments, source/destination issues, etc.)
* `2` - Backup completed but some files could not be copied (only in 'continue' error handling mode)

## EXAMPLES

* Basic backup:

  ```bash
  do-backup.sh --source /home/user --destination /mnt/backup/home
  ```

* Using parallel backup method:

  ```bash
  do-backup.sh -s /var -d /mnt/backup/var --method=parallel
  ```

* Continue on errors:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --error-handling=continue
  ```

* Exclude specific file types:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.log' --exclude='*.tmp'
  ```

* Exclude multiple directories:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --exclude='tmp/' --exclude='cache/' --exclude='.git/'
  ```

* Exclude specific paths:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --exclude='Downloads/large-files/' --exclude='Videos/'
  ```

* Using an exclude file:

  ```bash
  # First create an exclude file
  cat > exclude_patterns.txt << EOF
  # Comments are supported
  *.log
  *.tmp
  .git/
  node_modules/
  target/
  build/
  EOF

  # Then use it in the backup command
  do-backup.sh -s /home/user/projects -d /mnt/backup/projects --exclude-from=exclude_patterns.txt
  ```

* Combining exclude options:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.iso' --exclude-from=exclude_patterns.txt
  ```

* Non-interactive backup with excludes:

  ```bash
  do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.log' --non-interactive
  ```

## AUTOMATED USAGE

When using this script in automated environments, testing frameworks, or any non-interactive context, always use the `--non-interactive` flag. This is critical because without this flag, the script will prompt for user input in certain scenarios, which can cause automation to hang indefinitely.

The `--non-interactive` flag ensures that:

* The script will not wait for user confirmation at any point
* Default values will be used when decisions are needed
* Error messages will still be displayed for logging purposes
* The script will exit with appropriate error codes on failure

Scenarios where the script might prompt for input without this flag:

* Empty source directory detection
* Confirmation of exclude patterns
* Handling of special files
* Error recovery options

Example for automated usage in a testing environment:

```bash
do-backup.sh -s /home/user -d /mnt/backup/home --exclude='*.log' --exclude='cache/' --non-interactive
```

Example for automated usage in a scheduled backup script:

```bash
do-backup.sh -s /var/www -d /mnt/backup/www --method=tar --error-handling=continue --non-interactive
```

## NOTES

* The script automatically handles hidden files and directories.
* When using the `--backup` flag with `create-subvolume.sh`, this script is called automatically.
* The script uses reflink copies when possible (on BTRFS filesystems) for efficiency.
* Empty source directories are handled gracefully, with a confirmation prompt in interactive mode.

## SEE ALSO

* `create-subvolume` - Creates BTRFS subvolumes with optional backup
* `configure-snapshots` - Configures BTRFS snapshot schedules

## AUTHOR

BTRFS Subvolume Tools Project
