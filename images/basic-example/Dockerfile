# shared based between container and vm
FROM docker.io/library/archlinux:base-devel AS base
ARG BX_USER
ARG BX_UID

# add archpkgs repo
#ADD https://github.com/dadevel/archpkgs/raw/main/setup.sh /tmp/setup.sh
#RUN pacman-key --init && bash /tmp/setup.sh && rm -f /tmp/setup.sh

# install basic system packages
RUN pacman -Syu --needed --noconfirm nmap kitty ttf-meslo-nerd

# add user
RUN useradd --create-home --user-group --groups audio,input,video --shell /bin/bash --uid $BX_UID $BX_USER && \
mkdir -p /home/$BX_USER/{.cache,.config} /run/user/$BX_UID && \
chown -R $BX_USER:$BX_USER /home/$BX_USER /run/user/$BX_UID

# enable persistent systemd user session
RUN mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/$BX_USER

# set capabilities for rootless usage
RUN setcap cap_net_raw=ep /usr/bin/nmap

# add dotfiles
#COPY --from=dotfiles --chown=$BX_USER:$BX_USER ./bash/. .
#COPY --from=dotfiles --chown=$BX_USER:$BX_USER ./tmux/. .


# container image
FROM base AS container
ARG BX_USER
ARG BX_UID

# disable problematic systemd services
RUN systemctl mask systemd-firstboot.service systemd-homed.service systemd-resolved.service systemd-networkd.service

# work around systemd failing to initialize machine id which results in broken dbus
COPY ./machine-id-setup.service /usr/local/lib/systemd/system/
COPY ./machine-id-setup.sh /usr/local/lib/
RUN systemctl enable machine-id-setup.service

# install container-specific system packages
RUN pacman -S --needed --noconfirm xwayland-satellite

# enable xwayland-satellite
COPY <<EOF /etc/systemd/user/xwayland-satellite.service.d/override.conf
[Unit]
BindsTo=
PartOf=
After=
Requisite=
ConditionPathExists=/run/user/$BX_UID/wayland-0

[Service]
ExecStartPre=systemctl --user set-environment XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0 DISPLAY=:0

[Install]
WantedBy=default.target
EOF
RUN mkdir -p /etc/systemd/user/default.target.wants && \
ln -s /usr/lib/systemd/user/xwayland-satellite.service /etc/systemd/user/default.target.wants/xwayland-satellite.service

# use systemd as container entrypoint
USER root
ENTRYPOINT ["/sbin/init"]
CMD []


# vm image
FROM base AS vm
ARG BX_USER
ARG BX_UID
ARG BX_SUDO_PASSWORD
ARG BX_SSH_PUBKEY

# adjust user
RUN usermod --append --groups wheel --password "$BX_SUDO_PASSWORD" $BX_USER && \
mkdir -p /home/$BX_USER/{project,.ssh,share} && \
echo "$BX_SSH_PUBKEY" > /home/$BX_USER/.ssh/authorized_keys && \
chown -R $BX_USER:$BX_USER /home/$BX_USER

# make image bootable, '--needed' is omitted on purpose, because 'glibc' must be reinstalled to get missing locales
RUN pacman -S --noconfirm base base-devel efibootmgr glibc linux mkinitcpio sudo

# install VM-specific system packages
# spice-vdagent on wayland didnt work
# sddm needed because spice-vdagent is broken in plasma session started directly from tty
RUN pacman -S --needed --noconfirm breeze kscreen pipewire pipewire-pulse plasma-desktop plasma-x11-session sddm spice-vdagent vulkan-virtio wireplumber xclip xdg-desktop-portal-kde xorg-xrandr

# copy over config files from sysroot dir
COPY ./sysroot/. /
RUN chmod 0440 /etc/sudoers

# generate fstab
COPY <<EOF /etc/fstab
project /home/$BX_USER/project virtiofs nofail,nodev,nosuid 0 0
share /home/$BX_USER/share virtiofs nofail,nodev,nosuid 0 0
EOF

# configure sddm auto-login
COPY <<EOF /etc/sddm.conf.d/custom.conf
[Autologin]
Session=plasmax11
User=$BX_USER
Relogin=false

[Theme]
Current=breeze
EOF

# place bootloader in boot partition
RUN mkdir -p /boot/EFI/{BOOT,systemd} && cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.efi && cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /boot/EFI/systemd/systemd-bootx64.efi

# reenable pacman sandbox, is disabled in container
RUN sed -i 's|^DisableSandbox|#DisableSandbox|' /etc/pacman.conf

# regenerate locales
RUN locale-gen

# enable systemd services
RUN systemctl enable sddm.service systemd-networkd.service systemd-resolved.service systemd-timesyncd.service

# set root ssh key
COPY <<EOF /root/.ssh/authorized_keys
$BX_SSH_PUBKEY
EOF

# somehow required to get dynamic resolution working
COPY --chown=$BX_UID:$BX_UID --chmod=0755 <<EOF /home/$BX_USER/.xsession
#!/bin/sh
sleep 5 && xrandr --output Virtual-1 --auto &
EOF

# disable lockscreen
COPY --chown=$BX_UID:$BX_UID <<EOF /home/$BX_USER/.config/kscreenlockerrc
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
EOF

# directives like 'ENTRYPOINT' and 'CMD' are ignored in VM images
