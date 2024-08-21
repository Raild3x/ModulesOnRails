#!/bin/bash

# Prompt for the package name
read -p "Enter the package name: " PACKAGE_NAME

# Navigate to the package directory
PACKAGE_DIR="lib/$PACKAGE_NAME"
if [ ! -d "$PACKAGE_DIR" ]; then
    echo "Package directory $PACKAGE_DIR does not exist."
    exit 1
fi

cd "$PACKAGE_DIR" || { echo "Failed to access $PACKAGE_DIR"; exit 1; }

# Extract the current version number from wally.toml
CURRENT_VERSION=$(grep '^version =' wally.toml | awk -F '"' '{print $2}')
if [ -z "$CURRENT_VERSION" ]; then
    echo "Could not find the version number in wally.toml."
    exit 1
fi

echo "Current version: $CURRENT_VERSION"

# Ask how to increment the version (major, minor, or patch)
read -p "Do you want to increment the version by major, minor, or patch? " INCREMENT_TYPE

# Split the version number into major, minor, and patch components
IFS='.' read -r -a VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR=${VERSION_PARTS[0]}
MINOR=${VERSION_PARTS[1]}
PATCH=${VERSION_PARTS[2]}

# Increment the version based on user input
case $INCREMENT_TYPE in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Invalid increment type. Please specify major, minor, or patch."
        exit 1
        ;;
esac

# Construct the new version number
NEW_VERSION="$MAJOR.$MINOR.$PATCH"

# Update the version number in wally.toml
sed -i.bak "s/^version = \"$CURRENT_VERSION\"/version = \"$NEW_VERSION\"/" wally.toml

# Confirm the update
echo "Version updated to $NEW_VERSION in wally.toml."

# Run wally publish
read -p "Do you want to publish the package now? (y/n) " PUBLISH
if [ "$PUBLISH" = "n" ]; then
    echo "Publishing skipped."
    exit 1
fi

echo "Clearing the package directory..."
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

echo "Publishing package to Wally..."
wally publish