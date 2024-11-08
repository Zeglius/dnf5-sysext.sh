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
    ^bash -c $"source /etc/os-release && echo $($field)"
}

def "main clean" [] {
    ^$"($SUDOIF)" rm -vrfd /var/cache/dnf5_sysext-*
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
        return true
    } else {
        return false
    }
}

# Unmerge systemd sysexts
def "main stop" [] {
    ^$"($SUDOIF)" systemctl stop systemd-sysext
}

# Install rpms in a system extension
def "main install" [
    --extname = dnf5_default_sysext  # Extension name
    --now                            # Restart systemd-sysext after transaction
    ...pkgs: string                  # Packages to install
] {
    if ($pkgs | length) <= 0 {
        print -e "ERROR: No package was specified"
        exit 1
    }

    if (^dnf5 -q repoquery ...$pkgs | lines | length) == 0 {
        error make -u {msg: "No package found"}
        exit 1
    }

    # Deactivate sysext for now
    main stop

    # Install extension
    main init
    let installroot = $EXT_DIR
    try {
        ^$"($SUDOIF)" mkdir -p $installroot
        ^$"($SUDOIF)" dnf5 install -y --use-host-config --installroot $installroot ...$pkgs
    } catch { error make {msg: "Something happened during installation step" } }

    # Delete os-release
    ^$"($SUDOIF)" rm $"($installroot)/usr/lib/os-release"

    # Ask to restart systemd-sysext
    if $now {
        ^systemctl start systemd-sysext
    } else {
        input -n 1 "Do you wish to restart systemd-sysext? [y/N]: "
        | str downcase
        | if $in == "y" {
            ^systemctl start systemd-sysext
        }
    }
}

def main [] {}