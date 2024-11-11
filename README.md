Simple script that allows to create and use [Systemd extensions](https://www.freedesktop.org/software/systemd/man/256/systemd-sysext.html) with specified packages for Fedora (>=41, dnf5 required), avoiding to deal with Fedora Atomic rpm-ostree layering.

## Requirements

This script relies on [Nushell](https://www.nushell.sh/), which can be easly installed with brew:

```sh
$ brew install nushell
```

> [!WARNING]
> - THIS SCRIPT IS IN EARLY STAGES. Use at your own risk
> - Do not deactivate systemd extensions if using an imporant program installed in it (Desktop Enviroments, databases, etc)

## Quick start

We will install Docker in an extension as an example.

First we download `dnf5-sysext.nu` and add execution permissions.

```sh
$ git clone https://github.com/Zeglius/dnf5-sysext.sh.git
$ cd dnf5-sysext.sh
$ chmod +x ./dnf5-sysext.nu
```

Try to execute it to see if is working

```sh
./dnf5-sysext.nu --help
```

We copy [docker repo](https://docs.docker.com/engine/install/fedora/#set-up-the-repository) file into `/etc/yum.repos.d`

```sh
$ curl "https://download.docker.com/linux/fedora/docker-ce.repo" | sudo tee /etc/yum.repos.d/docker.repo
```

And now, we create the systemd extension, and install in it docker-ce packages

```sh
$ ./dnf5-sysext.nu install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
```

Should show a prompt to confirm whenever start the extension.

Afterwards, all left is enabling docker.

```sh
$ systemctl enable --now docker
```

## Troubleshoot guide

As its experimental state implies, this script can render your PC inoperable. Here is a quick guide to fix it:

1. Boot into grub, press <kbd>e</kbd> to edit the kernel parameters, and append `systemd.mask=systemd-sysext.service` this to the penultimate line, <kbd>Ctrl</kbd> + <kbd>x</kbd> to boot.

2. Once logged in, remove the contents of `/var/lib/extensions/WHATEVER_EXT_NAME`, by default being `/var/lib/extensions/dnf5_sysext`

```sh
sudo rm -rf /var/lib/extensions/dnf5_sysext
```
