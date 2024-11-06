#!/usr/bin/bash

# Check if we have dnf5 installed in the system
type -P dnf5 &>/dev/null || {
    echo "ERROR: command dnf5 not found"
    exit 1
}

# Check we are running as root
[ "$EUID" -ne 0 ] && {
    echo "ERROR: This script must be ran as root."
    exit 1
}

# Root directory for system extensions
EXTENSIONS_DIR="/var/lib/extensions"

# Name of the extension
EXT_NAME="$1"

# All the following arguments are considered packages
PKGS=("${@:2}")

# Check params
if [ -z "$EXT_NAME" ] || [ "${#PKGS[@]}" -lt 1 ]; then
    echo "Usage: ${0##*/} EXTENSION_NAME PACKAGES..."
    exit 1
fi

# Create directory for this system extension
INSTALL_PATH="$EXTENSIONS_DIR/$EXT_NAME"
if [ -d "$INSTALL_PATH" ]; then
    echo "ERROR: Extension '$EXT_NAME' already exists. Please remove or choose a different name."
    exit 1
fi

mkdir -p "$INSTALL_PATH" || {
    echo "ERROR: Failed to create directory '$INSTALL_PATH'"
    exit 1
}

# Install the packages to the specified directory
echo "Installing packages to '$INSTALL_PATH'..."
printf '  - %s\n' "${PKGS[@]}"
dnf5 install --installroot="$INSTALL_PATH" --use-host-config --assumeyes "${PKGS[@]}"

# Verify installation
# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
    echo "ERROR: Installation failed"
    exit 1
fi

# Create necessary systemd sysext metadata
{
    echo "Setting up systemd sysext metadata for $EXT_NAME..."
    mkdir -p "$INSTALL_PATH/usr"

    # Remove $INSTALL_PATH/usr/lib/os-release to prevent colision with hosts os-release
    USR_OSRELEASE="$INSTALL_PATH/usr/lib/os-release"
    ETC_OSRELEASE="$INSTALL_PATH/etc/os-release"
    echo "Moving '$USR_OSRELEASE' to '$ETC_OSRELEASE'"
    mv "$USR_OSRELEASE" "$ETC_OSRELEASE" || {
        echo "ERROR: Couldnt move '$USR_OSRELEASE' to '$ETC_OSRELEASE'"
        exit 1
    }

    # Create an 'extension-release.d' directory with release info file
    RELEASE_DIR="$INSTALL_PATH/usr/lib/extension-release.d"
    mkdir -p "$RELEASE_DIR"

    # shellcheck disable=SC1091
    # Populate the release info file
    cat <<-EOF | tee "$RELEASE_DIR/extension-release.$EXT_NAME" >/dev/null
ID=$(
        . /etc/os-release
        echo "$ID"
    )
VERSION_ID=$(
        . /etc/os-release
        echo "$VERSION_ID"
    )
# SYSEXT_LEVEL=1
EOF
} || {
    echo "ERROR: Error at setting up systemd sysext metadata"
    exit 1
}

echo "System extension $EXT_NAME created successfully"

# Optionally activate the extension
read -r -p "Would you like to activate the extension now? [y/N]: " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    systemctl restart systemd-sysext
    echo "Activated $EXT_NAME. Run 'systemd-sysext status' to verify"
else
    echo "To activate the extension later, use: 'systemctl restart systemd-sysext'"
fi
