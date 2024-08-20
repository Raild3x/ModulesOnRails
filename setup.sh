#!/bin/bash

set -e

echo "Setting up your environment..."

# Define the source directory
SRC_DIR="src"

# Check if the source directory exists
if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory $SRC_DIR does not exist."
    exit 1
fi

for dir in "$SRC_DIR"/*/ ; do
    # Check if it's a directory
    if [ ! -d "$dir" ]; then
      # If not a directory, skip to the next iteration
      continue
    fi

    echo "Parsing directory: $dir"
    RAW_NAME="$(basename "$dir")"

    # Find and remove everything in the src directory except the RailUtil directory
    echo "Cleaning up directory $dir..."
    if ! find "$dir" -mindepth 1 -maxdepth 1 ! -path "$dir"/"$RAW_NAME" -exec rm -rf {} +; then
        echo "Error: Failed to remove files from $dir."
        exit 1
    fi
done

echo "Setup complete!"