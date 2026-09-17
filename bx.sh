#!/usr/bin/env bash
set -euo pipefail
shopt -s lastpipe

# base env vars
declare -xr XDG_DATA_HOME="${XDG_DATA_HOME:-}"
declare -xr XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
declare -xr WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
declare -xr SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}"

# constants, don't touch
declare -r BX_STATE_DIR="$HOME/.local/share/bx"
declare -r BX_RUN_DIR="${XDG_RUNTIME_DIR:-"/run/user/$UID"}/bx"
declare -r LABEL_WORKDIR=io.github.dadevel.bx.workdir
declare -r LABEL_IMAGE=io.github.dadevel.bx.image
declare -r LABEL_GUI=io.github.dadevel.bx.gui
declare -r LABEL_RAW_IFACE=io.github.dadevel.bx.raw_iface
declare -r LABEL_SSH_AGENT=io.github.dadevel.bx.ssh_agent

# extra options, env only
declare -r BX_IMAGE_PREFIX=localhost/bx
declare -r BX_USER="${USER:?username unspecified}"
declare -i BX_UID="${BX_UID:-1000}"
# directory shared between all projects
declare -r BX_SHARE_DIR="${BX_SHARE_DIR:-"$HOME/share"}"
# size of virtual VM disk, build requires size times three free space
declare -r BX_DISK_SIZE="${BX_DISK_SIZE:-32G}"
# qemu bridge interfaces
declare -r BX_EXTERNAL_BRIDGE="${BX_EXTERNAL_BRIDGE:-br-ext}"
declare -r BX_NAT_BRIDGE="${BX_NAT_BRIDGE:-br-nat}"
# vm user passwords, default is 'password'
declare -r BX_SUDO_PASSWORD="${BX_SUDO_PASSWORD:-\$6\$Z7Dnsb50IrdeT2nH\$KRg2ondSrgth0fUXQ4n2SrtbpvPRwcWlqIraOXYzDPUd.xf/rExoWr1XhLer0O9V9t2FSzPUysgXUQ406llQb/}"
# ssh private key storage path
declare -r BX_SSH_PRIVATE_KEY="${BX_SSH_PRIVATE_KEY:-"$HOME/.ssh/bx"}"
# paths to certain files, required for qemu
declare -r BX_VIRTIOFSD="${BX_VIRTIOFSD:-/usr/lib/virtiofsd}"
declare -r BX_OVMF_CODE="${BX_OVMF_CODE:-/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd}"
declare -r BX_OVMF_VARS="${BX_OVMF_VARS:-/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd}"
declare -r BX_SSH_PROXY="${BX_SSH_PROXY:-/usr/lib/systemd/systemd-ssh-proxy}"

# common options, defaults from env, override from command line
declare BX_RUNTIME="${BX_RUNTIME:-container}"
declare -i BX_GUI="${BX_GUI:-0}"
declare -i BX_REMOVE="${BX_REMOVE:-0}"
declare BX_NETWORK="${BX_NETWORK:-}"
declare BX_MOVE_IFACE="${BX_MOVE_IFACE:-}"
declare -i BX_CLAUDE="${BX_CLAUDE:-0}"
declare -i BX_CODEX="${BX_CODEX:-0}"
declare -i BX_SSH_AGENT="${BX_SSH_AGENT:-0}"
declare -i BX_RUN_AS_ROOT="${BX_RUN_AS_ROOT:-0}"
declare -a BX_RUN_COMMAND=()
declare -i BX_FOLLOW="${BX_FOLLOW:-0}"

# podman image build options, customize as needed
declare -ra BX_BUILD_ARGS=(
    #--build-context dotfiles="$HOME/dotfiles"
    #--build-context tools="$HOME/projects/private-git/tools"
)

# podman container create options
declare -ra BX_PODMAN_CREATE_ARGS=()

# custom qemu command line options
declare -ra BX_BOOT_ARGS=()

main() {
    case "${1:?action unspecified}" in
        up|down|enter|select|list|logs|build)
            "command_$1" "${@:2}"
            ;;
        *)
            echo 'usage: bx ACTION [OPTS...]'
            echo ''
            echo 'actions:'
            echo '  up       Create and start project environment'
            echo '  down     Stop or delete project environment'
            echo '  enter    Open shell inside project environment'
            echo '  select   Interactively search and enter project'
            echo '  list     Show projects'
            echo '  logs     Show logs'
            echo '  build    Rebuild template image'
            return 1
            ;;
    esac
}

command_up() {
    while (( $# )); do
        case "$1" in
            --runtime)
                BX_RUNTIME="${2:?runtime unspecified}"
                shift
                ;;
            --gui)
                BX_GUI=1
                ;;
            --no-gui)
                BX_GUI=0
                ;;
            --replace)
                BX_REMOVE=1
                ;;
            --no-replace)
                BX_REMOVE=0
                ;;
            --network)
                BX_NETWORK="${2:?network unspecified}"
                shift
                ;;
            --move-iface)
                BX_MOVE_IFACE="${2:?iface unspecified}"
                shift
                ;;
            --claude)
                BX_CLAUDE=1
                ;;
            --no-claude)
                BX_CLAUDE=0
                ;;
            --codex)
                BX_CODEX=1
                ;;
            --no-codex)
                BX_CODEX=0
                ;;
            --ssh-agent)
                BX_SSH_AGENT=1
                ;;
            --no-ssh-agent)
                BX_SSH_AGENT=0
                ;;
            --)
                break
                ;;
            -*)
                echo 'usage: bx up [OPTS...] IMAGE'
                echo ''
                echo 'general options:'
                echo '  --runtime container|vm  Set runtime'
                echo '  --replace               Destroy existing project environment if present'
                echo ''
                echo 'container options:'
                echo '  --gui                            Enable GUI support'
                echo '  --network private|host|none|...  Configure container networking, see "--network" in "man podman-run"'
                echo '  --move-iface IFACE               Move network interface from host into container'
                echo '  --claude                         Provide Claude Code data volume to container'
                echo '  --codex                          Provide Codex data volume to container'
                echo '  --ssh-agent                      Mount SSH agent from host into container'
                echo ''
                echo 'VM options:'
                echo '  --network nat|bridge|nat+bridge|none  Configure VM networking'
                return 1
                ;;
            *)
                BX_IMAGE="${1:?image unspecified}"
                ;;
        esac
        shift
    done
    "command_${BX_RUNTIME}_up"
}

command_container_up() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r container_name="bx-${project_name}"

    if (( BX_REMOVE )) && podman container inspect "${container_name}" --format '{{.State.Status}}' &> /dev/null; then
        command_container_down
    fi

    declare -a create_opts=(
        --name "${container_name}"
        --hostname "${project_name}"
        --userns=keep-id:uid=$BX_UID,gid=$BX_UID
        #--userns=auto:uidmapping=$BX_UID:$BX_UID:1,gidmapping=$BX_UID:$BX_UID:1
        --user 0:0
        --tz local
        --network "$BX_NETWORK"
        --sysctl net.ipv4.ip_unprivileged_port_start=0  # allow anyone inside the container to bind any port
        --volume "${project_root}:/home/$BX_USER/project:rw"
        --label "$LABEL_WORKDIR=${project_root}"
        --label "$LABEL_IMAGE=$BX_IMAGE"
        --volume "$BX_SHARE_DIR:/home/$BX_USER/share:rw"
    )
    if [[ "$BX_NETWORK" != none ]]; then
        # /dev/net/tun required for pasta
        create_opts+=(--device /dev/net/tun --cap-add net_admin)
    fi
    if [[ -n "$BX_MOVE_IFACE" ]]; then
        create_opts+=(--cap-add net_raw --label "$LABEL_RAW_IFACE=$BX_MOVE_IFACE")
    fi
    if (( BX_GUI )); then
        # x11 is not supported on porpuse because security
        if [[ -z "$WAYLAND_DISPLAY" || ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
            echo 'error: no wayland display found' >&2
            return 1
        fi
        create_opts+=(
            --device /dev/dri
            --device /dev/snd
            --volume "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/run/user/$BX_UID/wayland-0:rw"
            --volume "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.lock:/run/user/$BX_UID/wayland-0.lock:rw"
            --label "$LABEL_GUI=true"
        )
        if [[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]]; then
            create_opts+=(--volume "$XDG_RUNTIME_DIR/pipewire-0:/run/user/$BX_UID/pipewire-0")
        fi
        if [[ -S "$XDG_RUNTIME_DIR/pulse/native" ]]; then
            create_opts+=(--volume "$XDG_RUNTIME_DIR/pulse/native:/run/user/$BX_UID/pulse/native")
        fi
    fi
    if (( BX_CLAUDE )); then
        create_opts+=(--volume "claude-data:/home/$BX_USER/.claude:rw")
    fi
    if (( BX_CODEX )); then
        echo 'error: option not implemented yet' >&2
        return 1
    fi
    if (( BX_SSH_AGENT )); then
        if [[ -z "$SSH_AUTH_SOCK" ]]; then
            echo 'error: no ssh agent found' >&2
            return 1
        fi
        create_opts+=(
            --volume "$SSH_AUTH_SOCK:/run/user/$BX_UID/ssh-agent.socket:rw"
            --label "$LABEL_SSH_AGENT=true"
        )
    fi

    podman container create "${create_opts[@]}" "${BX_PODMAN_CREATE_ARGS[@]}" "$BX_IMAGE_PREFIX/$BX_IMAGE:container" > /dev/null
}

command_vm_up() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r run_dir="$BX_RUN_DIR/${project_name}"
    declare -r state_dir="$BX_STATE_DIR/${project_name}"
    declare -r disk_template="$(dirname "$(realpath "$0")")/images/$BX_IMAGE.raw"

    if (( BX_REMOVE )); then
        command_vm_down
    fi

    mkdir -p "${run_dir}" "${state_dir}"

    if [[ ! -f "${state_dir}/disk.raw" ]]; then
        rsync "${disk_template}" "${state_dir}/disk.raw"
    fi
    if [[ ! -f "${state_dir}/efi.raw" ]]; then
        rsync "$BX_OVMF_VARS" "${state_dir}/efi.raw"
    fi

    if [[ -f "${state_dir}/id.txt" ]]; then
        declare -r project_id="$(< "${state_dir}/id.txt")"
    else
        declare -r project_id="$(openssl rand -hex 3 | tee "${state_dir}/id.txt")"
    fi

    mkdir -p "${state_dir}/labels"
    echo "${project_root}" > "${state_dir}/labels/$LABEL_WORKDIR"
    echo "$BX_IMAGE" > "${state_dir}/labels/$LABEL_IMAGE"

    declare -r hostname="bx-${project_name}"
    declare -r mac_address_1="52:54:01$(echo -n "${project_id}" | sed -E 's|(..)|:\1|g')"
    declare -r mac_address_2="52:54:02$(echo -n "${project_id}" | sed -E 's|(..)|:\1|g')"
    declare -r vm_interface="tap-bx-${project_id}"
    declare -r vsock_cid="$(printf '%d' "0x${project_id}")"

    declare interface
    for interface in "${vm_interface}-1" "${vm_interface}-2"; do
        if ! ip link show "${interface}" &> /dev/null; then
            sudo ip tuntap add mode tap "${interface}"
        fi
    done
    case "$BX_NETWORK" in
        ''|nat)
            sudo ip link set dev "${vm_interface}-1" master "$BX_NAT_BRIDGE"
            sudo ip link set dev "${vm_interface}-2" nomaster
            ;;
        bridge)
            sudo ip link set dev "${vm_interface}-1" nomaster
            sudo ip link set dev "${vm_interface}-2" master "$BX_EXTERNAL_BRIDGE"
            ;;
        nat+bridge|bridge+nat)
            sudo ip link set dev "${vm_interface}-1" master "$BX_NAT_BRIDGE"
            sudo ip link set dev "${vm_interface}-2" master "$BX_EXTERNAL_BRIDGE"
            ;;
        none)
            sudo ip link set dev "${vm_interface}-1" nomaster
            sudo ip link set dev "${vm_interface}-2" nomaster
            ;;
        *)
            echo 'error: invalid network mode' >&2
            return 1
            ;;
    esac
    sudo ip link set "${vm_interface}-1" up
    sudo ip link set "${vm_interface}-2" up

    systemd-run --user --unit "bx-${project_name}-virtiofsd-project.service" --nice 10 -- "$BX_VIRTIOFSD" --socket-path "${run_dir}/virtiofs-project.sock" --shared-dir "${project_root}"
    systemd-run --user --unit "bx-${project_name}-virtiofsd-share.service" --nice 10 -- "$BX_VIRTIOFSD" --socket-path "${run_dir}/virtiofs-share.sock" --shared-dir "$BX_SHARE_DIR"

    declare qemu_args=(
        -name "${hostname}"

        # direct kernel boot instead of efi
        #-kernel "${state_dir}/vmlinuz-linux" -append 'root=LABEL=root rw'

        # efi
        -drive if=pflash,format=raw,unit=0,file="$BX_OVMF_CODE",readonly=on
        -drive if=pflash,format=raw,unit=1,file="${state_dir}/efi.raw"
        -boot order=d,menu=on

        # storage
        -drive media=disk,file="${state_dir}/disk.raw",format=raw,if=virtio,aio=native,cache.direct=on,discard=unmap

        # ram, memory backend required for virtiofs
        -m size=8g
        -device virtio-balloon
        -object memory-backend-memfd,id=mem,size=8G,share=on -numa node,memdev=mem

        # compute
        -cpu host -smp dies=1,sockets=1,cores=2,threads=2
        -machine type=q35,accel=kvm -enable-kvm
        -device intel-iommu

        # networking
        -netdev type=tap,id=network1,ifname="${vm_interface}-1",script=no,downscript=no
        -device driver=virtio-net,netdev=network1,mac="${mac_address_1}"
        -netdev type=tap,id=network2,ifname="${vm_interface}-2",script=no,downscript=no
        -device driver=virtio-net,netdev=network2,mac="${mac_address_2}"

        # video

        # gl video, best practice according to quickemu, noticed some stutters
        -vga none  # taken over by spice
        -device virtio-gpu-gl
        -display egl-headless
        -device virtio-serial-pci

        # qxl video, requires x11, supports dynamic display resolution, noticed some freezes
        #-vga none
        #-device qxl-vga,vgamem_mb=32
        #-device virtio-serial-pci

        # '-display sdm' doesn't have clipboard sharing, dynamic display doesn't work either
        # '-display gtk' is supposed to have clipboard sharing but apparently doesn't, dynamic display worked on x11
        # '-display dbus' requires 'qemu-vnc' which is nowhere to be found
        # '-device virtio-gpu-rutabaga' seems experimental and guest-site setup is unclear
        # '-vnc :0' seems to have no clipboard sharing, also no dynamic display

        # spice
        -spice unix=on,addr="${run_dir}/spice.sock",disable-ticketing=on
        -chardev spicevmc,id=vdagent0,name=vdagent
        -device virtserialport,chardev=vdagent0,name=com.redhat.spice.0

        # usb keyboard and mouse
        -usb
        -device usb-ehci,id=input
        -device usb-kbd,bus=input.0
        -device usb-tablet,bus=input.0

        # spice usb redirection
        -device qemu-xhci,id=spicepass
        -chardev spicevmc,id=usbredirchardev1,name=usbredir
        -device usb-redir,chardev=usbredirchardev1,id=usbredirdev1
        -device pci-ohci,id=smartpass
        -device usb-ccid

        # audio
        -audiodev pipewire,id=audio0
        -device intel-hda
        -device hda-duplex,audiodev=audio0

        # virtiofs, '-virtfs' uses the older virtio 9p backend
        -chardev socket,id=char0,path="${run_dir}/virtiofs-project.sock" -device vhost-user-fs-pci,chardev=char0,tag=project
        -chardev socket,id=char1,path="${run_dir}/virtiofs-share.sock" -device vhost-user-fs-pci,chardev=char1,tag=share

        # systemd vm interface, see https://systemd.io/VM_INTERFACE/
        # sshd on vsock
        -device vhost-vsock-pci,id=vhost-vsock-pci0,guest-cid="${vsock_cid}"
        # config pass through
        -smbios type=11,value=io.systemd.credential.binary:system.hostname="$(echo -n "${hostname}" | base64 -w0)"

        # misc
        -device virtio-rng-pci,rng=rng0 -object rng-random,id=rng0,filename=/dev/urandom
    )

    systemd-run --user --unit "bx-${project_name}-qemu.service" --nice 10 -- qemu-system-x86_64 "${qemu_args[@]}" "${BX_BOOT_ARGS[@]}"
}

command_down() {
    while (( $# )); do
        case "$1" in
            --runtime)
                BX_RUNTIME="${2:?runtime unspecified}"
                shift
                ;;
            --remove)
                BX_REMOVE=1
                ;;
            --no-remove)
                BX_REMOVE=0
                ;;
            *)
                echo 'usage: bx down [OPTS...]'
                echo ''
                echo 'general options:'
                echo '  --runtime container|vm  Set runtime'
                echo '  --remove                Delete project environment'
                return 1
                ;;
        esac
        shift
    done
    "command_${BX_RUNTIME}_down"
}

command_container_down() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r container_name="bx-${project_name}"

    declare -r raw_nic="$(podman container inspect "${container_name}" --format "{{index .Config.Labels \"$LABEL_RAW_IFACE\"}}")"
    if [[ -n "${raw_nic}" ]]; then
        declare -i pid="$(podman inspect --format '{{.State.Pid}}' "${container_name}")"
        if (( pid >= 0 )); then
            if nsenter --target "${pid}" --user --net -- ip link show "${raw_nic}" &> /dev/null; then
                echo ">> moving interface ${raw_nic} from container back to host" >&2
                sudo nsenter --target "${pid}" --net -- ip link set "${raw_nic}" netns 1
            fi
        fi
    fi
    podman container stop -- "${container_name}" > /dev/null
    if (( BX_REMOVE )); then
        podman container rm -- "${container_name}" > /dev/null
    fi
}

command_vm_down() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r project_id="$(< "$BX_STATE_DIR/${project_name}/id.txt")"
    declare -r vsock_cid="$(printf '%d' "0x${project_id}")"

    if (( ! BX_REMOVE )); then
        timeout 15 ssh -F /dev/null -i "${BX_SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ProxyCommand="$BX_SSH_PROXY %h %p" -o ProxyUseFdpass=yes -o "root@vsock/${vsock_cid}" systemctl poweroff ||:
    fi

    systemctl --user stop "bx-${project_name}-*.service"
    systemctl --user reset-failed "bx-${project_name}-*.service"

    if (( BX_REMOVE )); then
        rm -rf "$BX_STATE_DIR/${project_name}"
    fi

    # let network interface linger to avoid sudo prompt during shutdown
}

command_enter() {
    while (( $# )); do
        case "$1" in
            --runtime)
                BX_RUNTIME="${2:?runtime unspecified}"
                shift
                ;;
            --gui)
                BX_GUI=1
                ;;
            --no-gui)
                BX_GUI=0
                ;;
            --root)
                BX_RUN_AS_ROOT=1
                ;;
            --no-root)
                BX_RUN_AS_ROOT=0
                ;;
            --ssh-agent)
                BX_SSH_AGENT=1
                ;;
            --no-ssh-agent)
                BX_SSH_AGENT=0
                ;;
            --)
                break
                ;;
            -*)
                echo 'usage: bx enter [OPTS...] [COMMAND...]'
                echo ''
                echo 'general options:'
                echo '  --runtime container|vm  Set runtime'
                echo '  --root                  Run command as root, ignored with --gui'
                echo ''
                echo 'qemu options:'
                echo '  --gui        Open spice UI'
                echo '  --ssh-agent  Forward SSH agent from host to VM, ignored with --gui'
                return 1
                ;;
            *)
                break
                ;;
        esac
        shift
    done
    BX_RUN_COMMAND=("$@")
    "command_${BX_RUNTIME}_enter"
}

command_container_enter() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r container_name="bx-${project_name}"
    declare -r container_workdir="/home/$BX_USER/project/$(realpath --relative-to="${project_root}" "$PWD")"

    declare -r status="$(podman container inspect "${container_name}" --format '{{.State.Status}}' 2> /dev/null)"
    case "${status}" in
        running)
            ;;
        created)
            podman container start "${container_name}" > /dev/null
            ;;
        *)
            echo "error: container has unexpected status ${status:-absent}" >&2
            return 1
            ;;
    esac

    declare -r raw_nic="$(podman container inspect "${container_name}" --format "{{index .Config.Labels \"$LABEL_RAW_IFACE\"}}")"
    if [[ -n "${raw_nic}" ]]; then
        declare -i pid="$(podman inspect --format '{{.State.Pid}}' "${container_name}")"
        if (( pid <= 0 )); then
            echo "error: container has no pid" >&2
            return 1
        fi
        if ! nsenter --target "${pid}" --user --net -- ip link show "${raw_nic}" &> /dev/null; then
            echo ">> moving interface ${raw_nic} from host to container" >&2
            sudo ip link set "${raw_nic}" nomaster
            sudo ip link set "${raw_nic}" netns "${pid}"
            # work around network interface hanging in "state down" + "NO-CARRIER" forever
            sudo nsenter --target "${pid}" --net -- ip link set "${raw_nic}" up
            sudo nsenter --target "${pid}" --net -- ethtool -r "${raw_nic}"
        fi
    fi

    declare -a exec_opts=(
        --interactive
        --tty
        --workdir "${container_workdir}"
        --env TERM
        --env BX_PROJECT_NAME="${project_name}"
    )
    if (( BX_RUN_AS_ROOT )); then
        exec_opts+=(--env HOME=/root --user 0:0)
    else
        exec_opts+=(--env HOME="/home/$BX_USER" --user "$BX_UID:$BX_UID")
    fi
    if [[ "$(podman container inspect "${container_name}" --format "{{index .Config.Labels \"$LABEL_GUI\"}}")" == true ]]; then
        exec_opts+=(
            --env XDG_CURRENT_DESKTOP
            --env XDG_RUNTIME_DIR="/run/user/$BX_UID"
            --env XDG_SEAT
            --env XDG_SESSION_CLASS
            --env XDG_SESSION_ID
            --env XDG_SESSION_TYPE=wayland
            --env DISPLAY=:0
            --env WAYLAND_DISPLAY=wayland-0
            --env _JAVA_AWT_WM_NONREPARENTING=1
        )
    fi
    if [[ "$(podman container inspect "${container_name}" --format "{{index .Config.Labels \"$LABEL_SSH_AGENT\"}}")" == true ]]; then
        exec_opts+=(--env SSH_AUTH_SOCK="/run/user/$BX_UID/ssh-agent.socket")
    fi

    if [[ -z "${BX_RUN_COMMAND[@]}" ]]; then
        BX_RUN_COMMAND+=(bash)
    fi
    exec podman exec "${exec_opts[@]}" "${container_name}" "${BX_RUN_COMMAND[@]}"
}

command_vm_enter() {
    declare -r project_root="$(git rev-parse --show-toplevel 2> /dev/null || echo "$PWD")"
    declare -r project_name="$(basename "${project_root}")"
    declare -r project_id="$(< "$BX_STATE_DIR/${project_name}/id.txt")"
    declare -r vsock_cid="$(printf '%d' "0x${project_id}")"
    declare -r run_dir="$BX_RUN_DIR/${project_name}"

    if (( BX_GUI )); then
        systemd-run --user --unit "bx-${project_name}-spicy.service" --nice 10 -- spicy --uri "spice+unix://${run_dir}/spice.sock"
        return
    fi

    mkdir -p "$BX_RUN_DIR"
    declare -a args=(-F /dev/null -i "${BX_SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ProxyCommand="$BX_SSH_PROXY %h %p" -o ProxyUseFdpass=yes -o ControlMaster=auto -o ControlPath="$BX_RUN_DIR/ssh-%C.sock")
    (( ! BX_SSH_AGENT )) || args+=(-A)
    (( BX_RUN_AS_ROOT )) && args+=("root@vsock/${vsock_cid}") || args+=("$BX_USER@vsock/${vsock_cid}")
    exec ssh "${args[@]}" "${BX_RUN_COMMAND[@]}"
}

command_select() {
    if (( $# != 0 )); then
        echo 'usage: bx select'
        return 1
    fi
    declare workdir
    {
        podman container ls --all --format json | jq -r '.[]|select(.Names[0]|startswith("bx-"))|"ctr \(.Names[0][3:]) \(.Labels."'"$LABEL_WORKDIR"'")"'

        for path in "$BX_STATE_DIR"/*; do
            if [[ ! -d "${path}" ]]; then
                continue
            fi
            declare project_name="$(basename "${path}")"
            printf '%s %s %s\n' vm "${project_name}" "$(< "${path}/labels/$LABEL_WORKDIR")"
        done
    } | fzf --no-multi | read -r runtime name workdir
    pushd "${workdir}"
    [[ "${runtime}" != ctr ]] || runtime=container
    "command_${runtime}_enter"
}

command_list() {
    if (( $# != 0 )); then
        echo 'usage: bx list'
        return 1
    fi
    {
        printf '%s\t%s\t%s\t%s\t%s\n' TYPE NAME WORKDIR IMAGE STATUS

        podman image ls --format '{{.Repository}}' | grep "^$BX_IMAGE_PREFIX/" | sed "s|^$BX_IMAGE_PREFIX/||" | sort -Vu | while read -r image; do
            printf '%s\t%s\t%s\t%s\t%s\n' img "${image%%:*}" '-' '-' '-'
        done

        podman container ls --all --format json | jq -r '.[]|select(.Names[0]|startswith("bx-"))|["ctr",.Names[0][3:],.Labels."'"$LABEL_WORKDIR"'",.Labels."'"$LABEL_IMAGE"'",(.Status|ascii_downcase)]|@tsv'

        for path in "$BX_STATE_DIR"/*; do
            if [[ ! -d "${path}" ]]; then
                continue
            fi
            declare project_name="$(basename "${path}")"
            printf '%s\t%s\t%s\t%s\t%s\n' vm "${project_name}" "$(< "${path}/labels/$LABEL_WORKDIR")" "$(< "${path}/labels/$LABEL_IMAGE")" "$(systemctl --user --quiet is-active "bx-${project_name}-qemu.service" && echo on || echo off)"
        done
    } | column -ts $'\t'
}

command_logs() {
    declare -a args=()
    while (( $# )); do
        case "$1" in
            --runtime)
                BX_RUNTIME="${2:?runtime unspecified}"
                shift
                ;;
            -f|--follow)
                args=(--follow)
                ;;
            --no-follow)
                args=()
                ;;
            *)
                echo 'usage: bx logs [OPTS...]'
                echo ''
                echo 'general options:'
                echo '  --runtime container|vm  Set runtime'
                echo '  -f|--follow             Watch logs'
                return 1
                ;;
        esac
        shift
    done
    case "$BX_RUNTIME" in
        podman)
            podman logs "${args[@]}" -- "$1"
            ;;
        qemu)
            journalctl --user --no-hostname --unit "bx-$1-*.service" "${args[@]}"
            ;;
    esac
}

command_build() {
    if (( $# != 1 )) || [[ "${1:-}" == -* ]]; then
        echo 'usage: bx build IMAGE|all'
        return 1
    fi
    if [[ "$1" == all ]]; then
        declare -ra dockerfiles=("$(dirname "$(realpath "$0")")"/images/*/Dockerfile)
    else
        declare -ra dockerfiles=("$(dirname "$(realpath "$0")")/images/$1/Dockerfile")
    fi
    declare dockerfile
    for dockerfile in "${dockerfiles[@]}"; do
        grep -Eiq '^FROM\s\S+?\sAS\scontainer$' "${dockerfile}" && declare -i container=1 || container=0
        grep -Eiq '^FROM\s\S+?\sAS\svm$' "${dockerfile}" && declare -i vm=1 || vm=0
        if (( container )) || (( !container && !vm )); then
            command_container_build "${dockerfile}"
        fi
        if (( vm )); then
            command_vm_build "${dockerfile}"
        fi
    done
}

command_container_build() {
    declare -r image_dir="$(dirname "$1")"
    declare -r image_name="$BX_IMAGE_PREFIX/$(basename "${image_dir}"):container"
    declare -r cache_dir="$BX_STATE_DIR/.cache"

    echo ">> building image ${image_name}" >&2

    mkdir -p "${cache_dir}/pacman/pkg"

    declare -a build_args=(
        --pull=always
        --volume "${cache_dir}/pacman:/var/cache/pacman:rw"
        --build-arg BX_USER="$BX_USER"
        --build-arg BX_UID="$BX_UID"
        --build-arg BX_SUDO_PASSWORD="$BX_SUDO_PASSWORD"
        --build-arg BX_SSH_PUBKEY="$(< "${BX_SSH_PRIVATE_KEY}.pub")"
        --target container
    )
    podman build "${build_args[@]}" "${BX_BUILD_ARGS[@]}" --tag "${image_name}" -- "${image_dir}"
}

command_vm_build() {
    declare -r cache_dir="$BX_STATE_DIR/.cache"
    declare -gr image_dir="$(dirname "$1")"
    declare -r image_name="$BX_IMAGE_PREFIX/$(basename "${image_dir}"):vm"
    declare -r disk_template="$(dirname "$(realpath "$0")")/images/$(basename "${image_dir}").raw"

    if [[ ! -f "${BX_SSH_PRIVATE_KEY}" ]]; then
        ssh-keygen -t ed25519 -C 'root@bx' -f "${BX_SSH_PRIVATE_KEY}"
    fi

    echo ">> building image ${image_name}" >&2
    sudo -v

    mkdir -p "${cache_dir}/pacman/pkg"

    declare -a build_args=(
        --pull=always
        --network host
        --no-hosts
        --volume "${cache_dir}/pacman:/var/cache/pacman:rw"
        --build-arg BX_USER="$BX_USER"
        --build-arg BX_UID="$BX_UID"
        --build-arg BX_SUDO_PASSWORD="$BX_SUDO_PASSWORD"
        --build-arg BX_SSH_PUBKEY="$(< "${BX_SSH_PRIVATE_KEY}.pub")"
        --target vm
        --squash-all
    )
    podman build "${build_args[@]}" "${BX_BUILD_ARGS[@]}" --tag "${image_name}" -- "${image_dir}"

    teardown() {
        rm -rf "${image_dir}/tmp"

        if mountpoint -q "${image_dir}/mnt"; then
            sudo umount -R "${image_dir}/mnt"
            rmdir "${image_dir}/mnt"
        fi

        if [[ -e /dev/loop0 ]]; then
            sudo losetup /dev/loop0 --detach-all
            sudo losetup /dev/loop0 --remove
        fi
    }
    trap teardown EXIT

    # backup previous disk image
    if [[ -f "${disk_template}" ]]; then
        mv "${disk_template}" "${disk_template}.bak"
    fi
    # create empty disk image
    rm -f "${disk_template}"
    truncate -s "$BX_DISK_SIZE" "${disk_template}"

    # create partitions
    sgdisk --zap-all "${disk_template}"
    sgdisk --new=0:0:+512M --typecode=0:ef00 --change-name=0:efi "${disk_template}"
    sgdisk --new=0:0:0 --typecode=0:8304 --change-name=0:system "${disk_template}"
    sgdisk --sort --print "${disk_template}"

    # mount disk
    sudo losetup --partscan /dev/loop0 "${disk_template}"

    # create filesystems
    sudo mkfs.fat -F 32 -n boot /dev/loop0p1
    sudo mkfs.ext4 -L root /dev/loop0p2

    # mount partitions
    mkdir "${image_dir}/mnt"
    sudo mount /dev/loop0p2 "${image_dir}/mnt"
    sudo mkdir -p "${image_dir}/mnt/boot"
    sudo mount /dev/loop0p1 "${image_dir}/mnt/boot"

    # copy container filesystem to disk
    rm -rf "${image_dir}/tmp"
    mkdir "${image_dir}/tmp"

    # 'podman build --output type=tar,dest=./sysroot.tar' does not preserve SUID/SGID bits, see https://github.com/podman-container-tools/buildah/issues/4463
    podman image save "${image_name}" | tar -x -f- -C "${image_dir}/tmp"
    sudo tar -x --preserve-permissions --numeric-owner --xattrs --xattrs-include='*' -f "${image_dir}/tmp/"????????????????????????????????????????????????????????????????.tar -C "${image_dir}/mnt"

    trap - EXIT
    teardown
}

rsync() {
    command rsync --progress --human-readable "$@"
}

main "$@"
