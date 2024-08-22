#!/bin/bash

# This Bash script sets up the environment for Wally packages so that you can recieve proper linting while you work.

set -e

echo "Setting up your environment..."

# Define the source directory
SRC_DIR="lib"
OG_DIR=$(pwd)


# Start from the current directory
current_dir=$(pwd)

# Loop until we find the project root file or reach the root directory
while [ "$current_dir" != "/" ]; do
  if [ -f "$current_dir/$SRC_DIR" ]; then
    echo "Found project root at: $current_dir"
    break
  fi
  current_dir=$(dirname "$current_dir")
done

# Check if the source directory exists
if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory $SRC_DIR does not exist."
    exit 1
fi

if [ $# -eq 0 ]; then
    NO_ARGUMENTS_PROVIDED=true
else
    NO_ARGUMENTS_PROVIDED=false
fi

for DIR in "$SRC_DIR"/*/ ; do

    # Check if it's a directory
    if [ ! -d "$DIR" ]; then
      # If not a directory, skip to the next iteration
      echo "Skipping non-directory: $DIR"
      continue
    fi

    # Check if the directory is in the arguments
    if [ "$NO_ARGUMENTS_PROVIDED" = false ]; then
        IS_ARGUMENT=false
        for ARG in "$@"; do
            if [ "$DIR" = "$SRC_DIR/$ARG/" ]; then
                IS_ARGUMENT=true
                break
            fi
        done
        if [ "$IS_ARGUMENT" = false ]; then
            echo "Skipping non-argument directory: $DIR"
            continue
        fi
    fi

    
    RAW_NAME="$(basename "$DIR")"
    echo "Parsing directory: $RAW_NAME"

    # Define an array of filenames to ignore
    IGNORE_LIST=("src" "default.project.json" "wally.toml")

    # Construct the find command with multiple -name options for ignoring files
    IGNORE_PATHS=""
    for IGNORE_FILE in "${IGNORE_LIST[@]}"; do
        IGNORE_PATHS+=" ! -name \"$IGNORE_FILE\""
    done

    # Combine the ignore paths with the find command
    COMMAND="find \"$DIR\" -mindepth 1 -maxdepth 1 $IGNORE_PATHS -exec rm -rf {} +"

    # Evaluate and execute the command
    if ! eval "$COMMAND"; then
        echo "Error: Failed to remove files from $DIR."
        exit 1
    fi
done


echo "Packages Removed!"