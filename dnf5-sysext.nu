#!/usr/bin/env -S nu

export-env {
    $env.EXTENSIONS_DIR = $env.EXTENSIONS_DIR? | default "/var/lib/extensions"
    $env.EXT_NAME = $env.EXT_NAME? | default "dnf5_sysext"
    $env.EXT_DIR = $"($env.EXTENSIONS_DIR)/($env.EXT_NAME)"

    if ($env.EXT_NAME | str contains "/") {
        error make -u {msg: "EXT_NAME cannot contain slashes"}
    }
}

module internal {
    export def --wrapped sudoif [...rest] {
        if (is-admin) {
            run-external $rest.0? ...($rest | range 1..-1 | default [])
        } else {
            ^sudo ...$rest
        }
    }

    export def with-cd [path: path, closure: closure] {
        cd $path
        $env.WITHCD_LVL = ($env.WITHCD_LVL? | default 0 | into int) + 1
        do $closure
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
    let meta_str = $"ID=('ID'|os_info)\nVERSION_ID=('VERSION_ID'|os_info)\n"
    sudoif mkdir -p ($meta_file | path dirname)
    $meta_str | sudoif tee $meta_file | ignore
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
    ^systemd-sysext list --json=short
    | if $json { return $in } else { $in }
    | from json
    | table -t none -i false
}

# Install rpms in a system extension
def "main install" [
    --now                # Restart systemd-sysext after transaction.
    --overlay            # EXPERIMENTAL. Use 'bootc usroverlay' to create a more lightweight extension. Only use in system with bootc.
    ...pkgs: string      # Packages to install.
] {
    if ($pkgs | is-empty) {
        error make -u {msg: "No package was specified"}
    }

    let installroot = $env.EXT_DIR
    if not ($env.EXT_NAME in (main list)) { main init }
    if not $overlay {
        # Legacy method (at the time of writting 13/11/2024)
        try {
            sudoif mkdir -p $installroot
            sudoif dnf5 install -y --use-host-config --installroot $installroot ...$pkgs
        } catch { error make {msg: "Something happened during installation step" } }
        # Clean dnf5 cache
        main clean
    } else {
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
            let mounts = ^findmnt /usr -t overlay --json 
                | from json
                | $in.filesystems
                | update options { split row "," | split column "=" | transpose -r -d };

            let usroverlay: record = $mounts | where { 
                $in.source == "overlay" and $in.options.lowerdir == "usr" 
            } | first

            let upper_dir = $usroverlay | get options.upperdir | path expand
            $upper_dir
        }
        try {sudoif cp -a $"($upper_dir)/." $installroot}
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
