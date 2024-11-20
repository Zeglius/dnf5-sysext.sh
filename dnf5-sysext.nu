#!/usr/bin/env -S nu

export-env {
    $env.EXTENSIONS_DIR = $env.EXTENSIONS_DIR? | default "/var/lib/extensions"
    $env.EXT_NAME = $env.EXT_NAME? | default "dnf5_sysext"
    $env.EXT_DIR = $"($env.EXTENSIONS_DIR)/($env.EXT_NAME)"
    $env.NU_LOG_LEVEL = if ($env.DEBUG? == "1") {"DEBUG"} else {""}

    if ($env.EXT_NAME | str contains "/") {
        error make -u {msg: "EXT_NAME cannot contain slashes"}
    }
}

module internal {
    export def --wrapped sudoif [...rest] {
        use std log
        if (is-admin) {
            log debug $"run-external ($rest.0?) ($rest | range 1..-1 | default [])"
            run-external $rest.0? ...($rest | range 1..-1 | default [])
        } else {
            log debug $"sudo (echo ...$rest)"
            ^sudo ...$rest
        }
    }

    export def with-cd [path: path, closure: closure] {
        cd $path
        $env.WITHCD_LVL = ($env.WITHCD_LVL? | default 0 | into int) + 1
        do $closure
    }

    # Run a closure inside an writable overlay, with the lower layer being the root filesystem.
    export def with-overlay [
        closure: closure
    ] {
        let mountpoint = ^mktemp -d
        let opts = {
            lowerdir: /
            upperdir: $env.EXT_DIR
            workdir: /var/cache/dnf5_sysext/workdir
        }

        sudoif mkdir -p $opts.workdir

        let opts_s = [
            "-t", "overlay", "overlay"
            "-o", $"lowerdir=($opts.lowerdir),upperdir=($opts.upperdir),workdir=($opts.workdir)"
        ]

        try {
            sudoif mount ...$opts_s $mountpoint
            with-cd $mountpoint $closure
            sudoif umount --type overlay --lazy $mountpoint
            sudoif rm -rf $opts.workdir
            sudoif rm -r $mountpoint
        } catch {|err|
            try { sudoif umount --type overlay --lazy $mountpoint }
            try { sudoif rm -rf $opts.workdir }
            try { rm -r $mountpoint }
            error make -u $err
        }
    }

    # Get a field from /etc/os-release
    export def os_info []: string -> string {
        let field = $in
        open /etc/os-release
        | lines
        | split column "=" key value
        | transpose --header-row --as-record
        | get $field
    }

    # Display a yes/no dialog, and run closures depending on the answer
    export def askyesno [
        msg: string             # Dialog to display
        yesclosure: closure     # Run when answer is 'y'
        noclosure?: closure     # Run when answer is not 'y'
    ] {
        input ($msg | str trim | $"($in) [y/N]: ")
        | str downcase
        | str trim
        | if $in == "y" {
            do $yesclosure
        } else if $noclosure != null {
            do $noclosure
        }
    }

    export def findmnt [path?: path, --type (-t): string] {
        let type_p: list = if ($type | is-not-empty) {
            [-t, $type]
        } else {[]}

        if ($path | is-not-empty) {
            ^findmnt $path ...$type_p --json
                    | from json
                    | $in.filesystems
        } else {
            ^findmnt ...$type_p --json
                | from json
                | $in.filesystems
        } | update options {
            split row ","
            | split column "="
            | transpose -r -d
            | update cells {$in | default ""}
            | into record
        }
    }

    export def list_ext [] {
        ^systemd-sysext list --json=short | from json
    }
}

use internal *

# Clean dnf5 cache of systemd extension
def "main clean" [] {
    sudoif dnf5 --installroot $env.EXT_DIR --use-host-config clean all
}

# Initialize a systemd extension directory, including `extension-release.NAME`.
#
# Use `EXT_NAME` to populate a custom extension
def "main init" [] {
    # Create metadata
    let meta_file = $"($env.EXT_DIR)/usr/lib/extension-release.d/extension-release.($env.EXT_NAME)"
    let meta_file_etc = $"($env.EXT_DIR)/etc/extension-release.d/extension-release.($env.EXT_NAME)"
    let meta_str = $"ID=('ID'|os_info)\nVERSION_ID=('VERSION_ID'|os_info)\n"
    sudoif mkdir -p ($meta_file | path dirname)
    sudoif mkdir -p ($meta_file_etc | path dirname)
    $meta_str | ^sudo tee $meta_file | ignore
    $meta_str | ^sudo tee $meta_file_etc | ignore
    if ($meta_file | path exists) {
        print -e $"Extension ($env.EXT_NAME) was initialized"
    }

    # Populate bin symlink
    do {
        let usr_bin = ($env.EXT_DIR | path join usr/bin)
        sudoif mkdir -p $usr_bin
        sudoif ln -Tsrf $usr_bin ($env.EXT_DIR | path join bin)
    }
}

# Delete the system extension.
#
# Use this ONLY when you want to start from zero
def "main remove" [
    --assumeyes (-y)  # Confirm removal
] {
    let extname = $env.EXT_NAME
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
            askyesno $"Do you want to remove '($target.path)'" {||} {return}
        }
        # Whenever systemd-sysext was 
        let was_active = ^systemctl is-active systemd-sysexts | str trim | $in == "active"
        if $was_active { main stop }
        sudoif rm -Ir $target.path
        print -e $"Extension ($extname) was removed"
        if $was_active { main start }
    }
}

# Unmerge/stop systemd extensions
def "main stop" [] {
    sudoif systemctl stop systemd-sysext
}

# Merge/start systemd extensions
def "main start" [] {
    sudoif systemctl start systemd-sysext
}

# Enable systemd-sysext. Equivalent to 'systemctl enable systemd-sysext'
def "main disable" [
    --now      # Stop after disabling service
] {
    if $now {
        sudoif systemctl disable --now systemd-sysext
    } else {
        sudoif systemctl disable systemd-sysext
    }
}

# Disable systemd-sysext. Equivalent to 'systemctl disable systemd-sysext'
def "main enable" [
    --now      # Stop after disabling service
] {
    if $now {
        sudoif systemctl enable --now systemd-sysext
    } else {
        sudoif systemctl enable systemd-sysext
    }
}

# List all systemd extensions
def "main list" [
    --json (-j)  # Output in json
] {
    list_ext
    | if ($json) {$in | to json | return $in} else {$in}
    | table -t none -i false
}

# Install rpms in a system extension
def "main install" [
    --now                           # Restart systemd-sysext after transaction.
    --mode: string = "default"      #
    --list-modes (-l)               # List available installation modes.
    ...pkgs: string                 # Packages to install.
] {
    let modes = [
        [name, description];
        [default, "Utilize 'dnf5 --installroot=EXT_DIR'"]
        [bootc-overlay, "EXPERIMENTAL. Use 'bootc usroverlay' to create a more lightweight extension. Only use in system with bootc."]
        [overlayfs, "Mount an overlayfs. with lowerdir being '/', and upperdir to EXT_DIR"]
    ]
    if $list_modes { $modes | table -t none -i false | print ; return }

    if ($pkgs | is-empty) {
        error make -u {msg: "No package was specified"}
    }

    let installroot = $env.EXT_DIR
    if not ($env.EXT_NAME in (list_ext | get name)) { main init }
    match $mode {
        "default" => {
            # Legacy method (at the time of writting 13/11/2024)
            try {
                sudoif mkdir -p $installroot
                sudoif dnf5 install -y --use-host-config --installroot $installroot ...$pkgs
            } catch { error make {msg: "Something happened during installation step" } }
            # Clean dnf5 cache
            main clean
        },

        "bootc-overlay" => {
            # Experimental method. Use 'bootc usroverlay' to fetch only 
            # modified/new files from a transaction.

            # Check we are in a system with bootc
            if (which bootc | is-empty) { error make -u {msg: "'bootc' not found. Try without the '--overlay' flag."} }

            # Enable the overlay
            try { sudoif bootc usroverlay }

            # Install stuff
            try {sudoif dnf5 install -y ...$pkgs}
            # Clean dnf5 cache
            sudoif dnf5 clean all -y

            # Find the upper layer
            let upper_dir: path = do {
                let mounts = findmnt /usr -t overlay

                let usroverlay: record = $mounts | where {
                    $in.source == "overlay" and $in.options.lowerdir == "usr"
                } | first

                let upper_dir = $usroverlay | get options.upperdir | path expand
                $upper_dir
            }
            try {sudoif cp -a $"($upper_dir)/." $installroot}
        },

        "overlayfs" => {
            with-overlay {
                main stop
                sudoif dnf5 --installroot $env.PWD install ...$pkgs
                sudoif dnf5 --installroot $env.PWD clean all
            }
        },

        _ => {
            error make -u {msg: ("Invalid mode selected. Use one of the following:\n"
            + ($modes.name | to yaml | str trim)
            )}
        }
    }

    # Delete os-release
    sudoif rm -f $"($installroot)/usr/lib/os-release"

    # Ask to restart systemd-sysext
    if $now {
        ^systemctl restart systemd-sysext
    } else {
        askyesno "Do you wish to restart systemd-sysext?" {
            ^systemctl restart systemd-sysext
        }
    }
}

# Pipe commands to dnf5 for an extension
def --wrapped "main dnf5" [...rest: string] {
    sudoif dnf5 --installroot $env.EXT_DIR --use-host-config ...$rest
}

def main [...command] {
    nu $"($env.CURRENT_FILE)" --help
    exit 1
}


alias "main help" = main --help
