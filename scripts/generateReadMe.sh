#!/bin/bash

SRC_DIR="lib"

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

# Get the remote URL of the repository
REMOTE_URL=$(git config --get remote.origin.url)

# Extract the repository name and owner from the URL
# For https://github.com/owner/repo.git
REPO_OWNER=$(echo "$REMOTE_URL" | sed -E 's#https://github.com/([^/]+)/.*#\1#')
REPO_NAME=$(echo "$REMOTE_URL" | sed -E 's#https://github.com/[^/]+/([^/]+)\.git#\1#')

# Print the repository owner and name
echo "Repository Owner: $REPO_OWNER"
echo "Repository Name: $REPO_NAME"
DOCS_LINK="https://raild3x.github.io/$REPO_NAME/"
echo "Docs Link: $DOCS_LINK"

# Output README file
README_FILE="README.md"

# Start the README file with a title and table header
cat <<EOF > "$README_FILE"
$REPO_NAME is a collection of Wally packages to streamline Roblox development.

# Packages

| Package | Latest Version | Description |
|---------|----------------|-------------|
EOF

echo "Generating README.md..."

# Iterate through each package directory
for PACKAGE_DIR in "$SRC_DIR"/*/ ; do
    # Check if it's a directory
    if [ -d "$PACKAGE_DIR" ]; then
        # Path to the wally.toml file
        WALLY_TOML="$PACKAGE_DIR/wally.toml"

        # Check if wally.toml exists
        if [ -f "$WALLY_TOML" ]; then

            echo "Parsing package directory: $PACKAGE_DIR"

            # Extract package name, version, and description
            FORMATTED_NAME=$(grep '^formattedName =' "$WALLY_TOML" | cut -d'=' -f2 | xargs)
            PACKAGE_DOCS_LINK=$(grep '^docsLink =' "$WALLY_TOML" | cut -d'=' -f2 | xargs)
            PACKAGE_NAME=$(grep '^name =' "$WALLY_TOML" | cut -d'=' -f2 | xargs)
            PACKAGE_VERSION=$(grep '^version =' "$WALLY_TOML" | cut -d'=' -f2 | xargs)
            PACKAGE_DESCRIPTION=$(grep '^description =' "$WALLY_TOML" | cut -d'=' -f2 | xargs)

            PACKAGE_DOCS_LINK="$DOCS_LINK$PACKAGE_DOCS_LINK"

            if [ -z "$FORMATTED_NAME" ]; then
                FORMATTED_NAME=$PACKAGE_NAME
                FORMATTED_NAME=$(echo "$FORMATTED_NAME" | sed 's/raild3x\///g')
                echo "No formatted name provided for $FORMATTED_NAME. Using package name as formatted name."
            fi

            # Append the package information to the README file
            cat <<EOF >> "$README_FILE"
| [$FORMATTED_NAME]($PACKAGE_DOCS_LINK) | \`$FORMATTED_NAME = "$PACKAGE_NAME@$PACKAGE_VERSION"\` | $PACKAGE_DESCRIPTION |
EOF
        else
            echo "Warning: $WALLY_TOML not found"
        fi
    else
        echo "Warning: $PACKAGE_DIR is not a directory"
    fi
done

echo "README.md has been generated successfully."