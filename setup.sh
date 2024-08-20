#!/bin/bash

set -e

echo "Setting up your environment..."

# Define the source directory
SRC_DIR="lib"
OG_DIR=$(pwd)

# Check if the source directory exists
if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory $SRC_DIR does not exist."
    exit 1
fi

for DIR in "$SRC_DIR"/*/ ; do
    # # Check if it's a directory
    # if [ ! -d "$DIR" ]; then
    #   # If not a directory, skip to the next iteration
    #   continue
    # fi

    
    RAW_NAME="$(basename "$DIR")"
    echo "\nParsing directory: $RAW_NAME"

    # Define an array of filenames to ignore
    IGNORE_LIST=("src" "default.project.json" "wally.lock" "wally.toml")

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
    dir

    # Install the Wally Packages
    echo "Installing Wally Package Dependencies..."
    if ! wally install; then
        echo "Error: Failed to install Wally packages."
        exit 1
    fi

    # # Generate the Wally Package Types
    # echo "Generating Wally Package Types..."
    # if ! wally-package-types --sourcemap sourcemap.json Packages; then
    #     echo "Error: Failed to generate Wally package types."
    #     exit 1
    # fi
done

cd "$OG_DIR"

# Ensure a sourcemap exists
echo "Generating sourcemap..."
if ! rojo sourcemap . -o sourcemap.json; then
    echo "Error: Failed to generate sourcemap."
    exit 1
fi

echo "Setup complete!"