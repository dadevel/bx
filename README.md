# bx

Manage per-project [Podman](https://podman.io/) containers or KVM+Qemu VMs to isolate your work.

## Setup

First, ensure some basic system packages are installed.

~~~ bash
sudo pacman -Syu --needed bash coreutils util-linux
~~~

Then, clone this repository and make [bx.sh](./bx.sh) available in your `$PATH`.

~~~ bash
git clone --depth 1 https://github.com/dadevel/bx.git
cd ./bx
ln -s -r ./bx.sh ~/.local/bin/bx
~~~

### Container Setup

Install additional system packages and configure rootless Podman.

~~~ bash
sudo pacman -Syu --needed ethtool iproute2 passt podman sudo
grep -qF containers: /etc/passwd 2> /dev/null || sudo useradd --system --no-user-group --home-dir / --no-create-home --shell /usr/bin/nologin containers
grep -qF containers: /etc/subuid 2> /dev/null || echo containers:2147483647:2147483648 | sudo tee -a /etc/subuid
grep -qF containers: /etc/subgid 2> /dev/null || echo containers:2147483647:2147483648 | sudo tee -a /etc/subgid
~~~

### VM Setup

Install additional system packages.
Most of these should already be installed anyway.

~~~ bash
sudo pacman -Syu --needed dosfstools e2fsprogs edk2-ovmf gptfdisk iproute2 openssh qemu-desktop rsync spice-gtk sudo systemd tar virtiofsd
~~~

Before you can boot your first VM, you have to set up networking.
The VMs will be connected to one or two bridge interfaces on the host.
The setup of this bridges is up to you.

The recommended configuration is:

1. A bridge interface called `br-nat` where the host provides a DHCP server that hands out IPs to the VMs + a firewall rule that performs network address translation (NAT). This bridge provides internet access to the VMs.
2. Optional: Another bridge interface called `br-ext` with a physical ethernet interface as member. This bridge gives the VMs raw access to the host network. Such a setup is often referred to as "bridge networking".

If you are using `systemd-networkd`, `systemd-resolved` and `nftables` you can use the config files provided in [etc](./etc).

## Usage

Build your first container and/or VM image.
If you later want to update the image, just run the same command again.

~~~
❯ bx build basic-example
~~~

> [!note]
> How the VM image is built:
>
> 1. Podman builds [images/basic-example/Dockerfile](./images/basic-example/Dockerfile). The only special requirement for this `Dockerfile` is, that it must ensure that the `/boot` directory contains all the expected contents of an EFI partition (bootloader, Linux kernel, etc.).
> 2. An empty file is created and loop-mounted. This makes the file appear like a physical disk. Then, partitions and filesystems are initialized on this "disk".
> 3. The content of the container image is copied onto these filesystems.
> 4. You have a bootable disk image.

Change into your project directory, spawn a container and get a shell inside.
Afterwards stop and delete the container.

~~~
❯ cd ~/projects/my-project
❯ bx up basic-example
❯ bx enter
user@basic-example ~/project $ echo doing work
user@basic-example ~/project $ exit
❯ bx down --remove
~~~

> [!note]
> `bx up` creates a new container or VM if none exists for the current project and starts it.  
> The current project directory will be available inside the project environment under `~/project`.
> When a Git repository is detected, the project directory is the repository root.
> Otherwise, the current working directory is used.  
> Additionally, `~/share` on the host is available in all projects under `~/share`.

Give a project raw access to a network interface by moving a physical ethernet interface into the container.

~~~
❯ bx up basic-example --move-iface eth0
❯ bx enter --root
root@basic-example /home/user/project # tcpdump -i eth0
...
~~~

> [!warning]
> If your internet connection is running over this network interface, your host will loose internet access until the project container is stopped.  
> In some situations you can use `bx up --network host` instead, but any actions that would require root privileges on the host won't work (e.g. reconfiguring network interfaces or using raw sockets).

Let a project container use the VPN connection established by another container.

~~~
❯ podman run -it --rm --name wg0 --cap-add net_admin -v ./wg0.conf:/etc/wireguard/wg0.conf:ro docker.io/library/alpine
# apk add --no-cache wireguard-tools iptables ip6tables
# wg-quick up wg0
~~~

~~~
❯ bx up basic-example --network container:wg0
❯ bx enter curl ipinfo.io
~~~

Spawn a project container that can run GUI programs.
The desktop environment on the host must use Wayland.

~~~
❯ bx up basic-example --gui
❯ bx enter kitty
~~~

> [!warning]
> Programs in the container have access to keyboard input, clipboard and window content of the host, because support for the `wp_security_context_v1` protocol is not implemented yet.

Spawn a project VM that is bridged to the same network as the host.
Then open a GUI window.

~~~
❯ bx up basic-example --runtime vm --network bridge
❯ bx enter --runtime vm --gui
~~~

Develop a custom image.

~~~
❯ cp -r ./images/basic-example ./images/my-image
❯ $EDTITOR ./bx.sh  # adjust BX_BUILD_ARGS as needed
❯ $EDTITOR ./images/my-image/Dockerfile  # add packages and files
~~~
