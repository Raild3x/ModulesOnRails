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

    cd "$DIR"

    # Install the Wally Packages
    echo "Installing Wally Package Dependencies..."
    if ! wally install; then
        echo "Error: Failed to install Wally packages."
        exit 1
    fi

    cd -> /dev/null
    # Ensure a sourcemap exists
    echo "Generating sourcemap..."
    if ! rojo sourcemap . -o sourcemap.json; then
        echo "Error: Failed to generate sourcemap."
        exit 1
    fi

    
    DIR_TO_MOVE="$DIR/Packages"
    if [ -d "$DIR_TO_MOVE" ]; then
        # Generate the Wally Package Types
        echo "Generating Wally Package Types..."
        if ! wally-package-types --sourcemap sourcemap.json "$DIR"Packages; then
            echo "Error: Failed to generate Wally package types."
            exit 1
        fi

        # Move the generated Wally files out of the Packages dir and into the src dir
        echo "Moving Wally Packages out of Packages directory..."

        # Move all visible files and directories
        if ! mv "$DIR_TO_MOVE"/* "$DIR" 2>/dev/null; then
            echo "Error: Failed to move visible files from $DIR_TO_MOVE to $DIR."
            exit 1
        fi
        echo "Moved visible files."

        # Remove the now-empty original directory
        echo "Removing original Packages directory..."
        if ! rmdir "$DIR_TO_MOVE"; then
            echo "Error: Failed to remove the original Packages directory."
            exit 1
        fi
    fi
done

# Ensure a sourcemap exists
echo "Regenerating sourcemap..."
if ! rojo sourcemap default.project.json -o sourcemap.json; then
    echo "Error: Failed to generate sourcemap."
    exit 1
fi


echo "Setup complete!  :D"