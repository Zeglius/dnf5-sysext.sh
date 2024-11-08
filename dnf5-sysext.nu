#!/usr/bin/env -S nu

let EXTENSIONS_DIR: string = $env.EXTENSIONS_DIR? | default "/var/lib/extensions"
let EXT_NAME: string = $env.EXT_NAME? | default "dnf5_sysext"
let EXT_DIR = $"($EXTENSIONS_DIR)/($EXT_NAME)"

let SUDOIF = if (is-admin) {""} else {"sudo"}

if ($EXT_NAME | str contains "/") {
    error make -u {msg: "EXT_NAME cannot contain slashes"}
}

# Get a field from /etc/os-release
def os_info []: string -> string {
    let field = $in
    open /etc/os-release
    | lines
    | split column "=" key value
    | transpose --header-row --as-record
    | get $field
}

# Clean dnf5 cache of systemd extension
def "main clean" [] {
    ^$"($SUDOIF)" dnf5 --installroot $EXT_DIR --use-host-config clean all
}

# Initialize a systemd extension directory, including `extension-release.NAME`.
#
# Use `EXT_NAME` to populate a custom extension
def "main init" [] {
    # Create metadata
    let meta_file = $"($EXT_DIR)/usr/lib/extension-release.d/extension-release.($EXT_NAME)"
    let meta_str = $"ID=('ID'|os_info)\nVERSION_ID=('VERSION_ID'|os_info)\n"
    ^$"($SUDOIF)" mkdir -p ($meta_file | path dirname)
    $meta_str | ^$"($SUDOIF)" tee $meta_file | ignore
    if ($meta_file | path exists) {
        print -e $"Extension ($EXT_NAME) was initialized"
    }
}

# Delete the system extension.
#
# Use this ONLY when you want to start from zero
def "main remove" [
    --assumeyes (-y)  # Confirm removal
] {
    let extname = $EXT_NAME
    let target = ^systemd-sysext list --json=short
    | from json
    | where name == $extname
    | get 0?
    | default {}

    if $target.path? == null {
        error make -u { msg: $"Extension '($extname)' not found" }
    } else {
        # We found the extension
        if not (is-terminal --stdin) and not $assumeyes {
            error make -u {msg: "Cannot access stdin. Use flag --assumeyes or run in an interactive terminal"}
        }
        # Check if we want to delete the extension
        if not $assumeyes {
            input $"Do you want to remove '($target.path)' [y/N]: "
            | str downcase
            | if $in != "y" {return}
        }
        main stop
        ^$"($SUDOIF)" rm -Ir $target.path
        echo "deleting something..."
        print -e $"Extension ($extname) was removed"
    }
}

# Unmerge/stop systemd extensions
def "main stop" [] {
    ^$"($SUDOIF)" systemctl stop systemd-sysext
}

# Merge/start systemd extensions
def "main start" [] {
    ^$"($SUDOIF)" systemctl start systemd-sysext
}

# List all systemd extensions
def "main list" [
    --json (-j)  # Output in json
] {
    ^systemd-sysext list --json=short
    | if $json { return $in } else { $in }
    | from json
    | table -t none -i false
}

# Install rpms in a system extension
def "main install" [
    --now                            # Restart systemd-sysext after transaction
    ...pkgs: string                  # Packages to install
] {
    if ($pkgs | length) <= 0 {
        print -e "ERROR: No package was specified"
        exit 1
    }

    if (^dnf5 -q repoquery ...$pkgs | lines -s | length) == 0 {
        error make -u {msg: "No package found"}
        exit 1
    }

    # Install extension
    if not ($EXT_NAME in (main list)) { main init }
    let installroot = $EXT_DIR
    try {
        ^$"($SUDOIF)" mkdir -p $installroot
        ^$"($SUDOIF)" dnf5 install -y --use-host-config --installroot $installroot ...$pkgs
    } catch { error make {msg: "Something happened during installation step" } }

    # Clean dnf5 cache
    main clean

    # Delete os-release
    ^$"($SUDOIF)" rm -f $"($installroot)/usr/lib/os-release"

    # Ask to restart systemd-sysext
    if $now {
        ^systemctl restart systemd-sysext
    } else {
        input -n 1 "Do you wish to restart systemd-sysext? [y/N]: "
        | str downcase
        | if $in == "y" {
            ^systemctl restart systemd-sysext
        }
    }
}

# Pipe commands to dnf5 for an extension
def --wrapped "main dnf5" [...rest: string] {
    ^$"($SUDOIF)" dnf5 --installroot $EXT_DIR --use-host-config ...$rest
}

def main [] {}