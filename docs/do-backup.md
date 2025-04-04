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

* `--exclude=PATTERN`  
  Exclude files/directories matching PATTERN. This option can be specified multiple times to exclude different patterns.

* `--exclude-from=FILE`  
  Read exclude patterns from FILE (one pattern per line).

## EXCLUDE PATTERNS

The `do-backup.sh` script supports excluding files and directories from the backup using glob-style patterns. This is useful for skipping temporary files, logs, caches, or other files that don't need to be backed up.

There are two ways to specify exclude patterns:

1. Using the `--exclude=PATTERN` option (can be specified multiple times)
2. Using the `--exclude-from=FILE` option to read patterns from a file (one pattern per line)

### Pattern Format

* Simple glob patterns: `*.log`, `tmp/`, etc.
* Patterns with `/` are relative to the source root
* Patterns without `/` match anywhere in the path

### Interactive Exclude Selection

You can use the `--show-excluded` option to interactively review and select which files and directories to exclude. This feature requires the `dialog` package to be installed.

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
# Exclude all log files and the tmp directory
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

#### Dependencies

The interactive exclude selection feature requires the `dialog` package to be installed:

* On Arch Linux: `sudo pacman -S dialog`
* On Debian/Ubuntu: `sudo apt install dialog`

If `dialog` is not installed, the script will fall back to the non-interactive mode and display a warning message.

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
