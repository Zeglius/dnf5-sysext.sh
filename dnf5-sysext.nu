#!/usr/bin/env -S nu

let EXTENSIONS_DIR: string = $env.EXTENSIONS_DIR? | default "/var/lib/extensions"

let SUDOIF = if (is-admin) {""} else {"sudo"}


# Create a temporary directory to store dnf5 transactions
def "get transaction_dir" []: list<string> -> string {
    let hash: string = $in | sort | reduce {|it, acc| $acc + " " + $it} | hash md5
    "/var/cache/dnf5_sysext-" + $hash
}

# Create a dnf5 transaction from a list of packages. 
# Outputs the path to the transaction
def generate_pkgs_trans []: list<string> -> string {
    let pkgs: list<string> = $in
    let transdir = $pkgs | get transaction_dir
    ^$SUDOIF mkdir -p $transdir
    try {
        ^$SUDOIF dnf5 -y install --use-host-config --store $transdir --setopt=install_weak_deps=False ($pkgs | str join)
    } catch {|err|
        ^$SUDOIF rm -rf $transdir
        return null
    }
    return $transdir
}

# Get a field from /etc/os-release
def os_info []: string -> string {
    let field = $in
    ^bash -c $"source /etc/os-release && echo $($field)"
}

def "main clean" [] {
    ^$SUDOIF rm -vrfd /var/cache/dnf5_sysext-*
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

    # First prepare the transaction
    let trans_path = $pkgs | generate_pkgs_trans

    # Deactivate sysext for now
    ^$SUDOIF systemctl stop systemd-sysext

    # Install extension
    let installroot = $"($EXTENSIONS_DIR)/($extname)"
    ^$SUDOIF mkdir -p $installroot
    ^$SUDOIF dnf5 replay -y --use-host-config --ignore-extras --installroot $installroot $trans_path

    # Delete os-release
    ^$SUDOIF rm $"($installroot)/usr/lib/os-release"

    # Add metadata
    let meta_path = $"($installroot)/usr/lib/extension-release.d/extension-release.($extname)"
    let meta_str = $"ID=('ID'|os_info)\nVERSION_ID=('VERSION_ID'|os_info)\n"
    ^$SUDOIF mkdir -p ($meta_path | path dirname)
    $meta_str | save -f $meta_path

    # Ask to restart systemd-sysext
    if $now {
        ^systemctl start systemd-sysext
    } else {
        let choice: string = input -n 1 "Do you wish to restart systemd-sysext? [y/N]: "
            | str downcase ;
        if $choice == "y" {
            ^systemctl start systemd-sysext
        }
    }
}

def main [] {}