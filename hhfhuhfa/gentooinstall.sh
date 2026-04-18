#!/usr/bin/env bash
# =============================================================================
#  Gentoo Linux Professional Installation Script (Solidified Version)
#  Target: /dev/nvme0n1 | Root: p4 | Boot: p6
#  Design: Offline Stage3 Loading, High Stability, Security Hardened
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --- Configuration ---
readonly DISK="/dev/nvme0n1"
readonly ROOT_PART="${DISK}p4"
readonly EFI_PART="${DISK}p6"
readonly MOUNT_POINT="/mnt/gentoo"
readonly ARCH="amd64"

# --- Visuals ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
log_step()  { echo -e "\n${BLUE}${BOLD}>>> $*${NC}"; }

# --- Safety Traps ---
cleanup() {
    log_info "Cleaning up mount points..."
    set +e
    if mountpoint -q "${MOUNT_POINT}/boot/efi"; then umount -l "${MOUNT_POINT}/boot/efi"; fi
    for dev in /run /dev/pts /dev/shm /dev /sys /proc; do
        if mountpoint -q "${MOUNT_POINT}${dev}"; then umount -l "${MOUNT_POINT}${dev}"; fi
    done
    if mountpoint -q "${MOUNT_POINT}"; then umount -l "${MOUNT_POINT}"; fi
    log_info "Cleanup complete."
}
trap cleanup EXIT
trap 'log_fatal "Interrupted by user."' INT TERM

# --- Hardware Detection ---
get_optimal_jobs() {
    local nproc mem_total mem_jobs final_jobs
    nproc=$(nproc)
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_jobs=$(( mem_total / 2048000 ))
    final_jobs=$(( nproc < mem_jobs ? nproc : mem_jobs ))
    if (( final_jobs < 1 )); then final_jobs=1; fi
    echo "$final_jobs"
}

# --- Core Functions ---
check_env() {
    log_step "Verifying Environment"
    [[ $EUID -eq 0 ]] || log_fatal "Must run as root."
    [[ -b "$DISK" ]] || log_fatal "Disk $DISK not found."
    [[ -d /sys/firmware/efi/efivars ]] || log_fatal "Not in UEFI mode."
    
    lsblk "$ROOT_PART" >/dev/null 2>&1 || log_fatal "Root partition $ROOT_PART does not exist."
    lsblk "$EFI_PART" >/dev/null 2>&1 || log_fatal "EFI partition $EFI_PART does not exist."
    
    log_info "Environment validated. Targets: Root=$ROOT_PART, EFI=$EFI_PART"
}

prepare_disk() {
    log_step "Preparing Partitions"
    swapoff -a || true
    umount -l "$ROOT_PART" 2>/dev/null || true
    umount -l "$EFI_PART" 2>/dev/null || true

    log_info "Formatting EFI partition ($EFI_PART)..."
    mkfs.fat -F32 -n "GENTOO_EFI" "$EFI_PART"
    
    log_info "Formatting Root partition ($ROOT_PART)..."
    mkfs.ext4 -F -L "GENTOO_ROOT" "$ROOT_PART"
    
    sync && partprobe "$DISK"
    sleep 2
}

mount_system() {
    log_step "Mounting Filesystems"
    mkdir -p "$MOUNT_POINT"
    mount "$ROOT_PART" "$MOUNT_POINT"
    mkdir -p "$MOUNT_POINT/boot/efi"
    mount "$EFI_PART" "$MOUNT_POINT/boot/efi"
    log_info "Mounting complete."
}

deploy_stage3() {
    log_step "Handling Pre-downloaded Stage3"
    
    # 현재 디렉토리에서 가장 최신 stage3 tarball 찾기
    local local_stage3
    local_stage3=$(ls stage3-amd64-desktop-openrc-*.tar.xz 2>/dev/null | sort -V | tail -n1 || true)
    
    if [[ -z "$local_stage3" ]]; then
        echo -e "${YELLOW}Stage3 파일이 없습니다!${NC}"
        echo -e "1. https://www.gentoo.org/downloads/mirrors/ 사이트에 접속하세요."
        echo -e "2. 가까운 미러를 선택해 releases/amd64/autobuilds/ 경로로 들어갑니다."
        echo -e "3. stage3-amd64-desktop-openrc-XXXXXXXXXXXXXX.tar.xz 파일을 다운로드하세요."
        echo -e "4. 다운로드한 파일을 이 스크립트(${0##*/})와 같은 폴더에 넣고 다시 실행하세요."
        log_fatal "Stage3 tarball missing in current directory."
    fi

    log_info "Found Stage3: $local_stage3"
    log_info "Copying to mount point..."
    cp "$local_stage3" "$MOUNT_POINT/"
    
    cd "$MOUNT_POINT"
    log_info "Extracting Stage3..."
    tar xpf "$local_stage3" --xattrs-include='*.*' --numeric-owner
    
    log_info "Cleaning up temporary tarball..."
    rm -f "$local_stage3"
    cd - >/dev/null
}

configure_base() {
    log_step "Configuring Base System"
    local jobs
    jobs=$(get_optimal_jobs)
    
    cat > "${MOUNT_POINT}/etc/portage/make.conf" <<EOF
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${jobs}"
EMERGE_DEFAULT_OPTS="--with-bdeps=y --binpkg-respect-use=y --getbinpkg=y --autounmask-write=n --jobs=${jobs} --load-average=${jobs}"
ACCEPT_LICENSE="*"
USE="unicode nls efi elogind dbus policykit pipewire wayland plasma"
VIDEO_CARDS="intel amdgpu radeonsi nvidia"
GRUB_PLATFORMS="efi-64"
EOF

    cp --dereference /etc/resolv.conf "${MOUNT_POINT}/etc/resolv.conf"
    
    for dev in /proc /sys /dev /run; do
        mount --rbind "$dev" "${MOUNT_POINT}${dev}"
        mount --make-rslave "${MOUNT_POINT}${dev}"
    done
}

run_chroot_install() {
    log_step "Entering Chroot for Finalization"
    local root_uuid efi_uuid
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    efi_uuid=$(blkid -s UUID -o value "$EFI_PART")

    cat > "${MOUNT_POINT}/tmp/install.sh" <<EOF
#!/bin/bash
source /etc/profile
export PS1="(chroot) \$PS1"

log() { echo -e "\${GREEN}[CHROOT]\${NC} \$*"; }

log "Syncing Portage"
emerge-webrsync -q

log "Selecting Profile"
eselect profile set \$(eselect profile list | grep "desktop/plasma" | grep -v "systemd" | head -n1 | awk '{print \$1}' | tr -d '[]')

log "Configuring Timezone & Locale"
echo "Asia/Seoul" > /etc/timezone
emerge --config sys-libs/timezone-data -q
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ko_KR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen -q
eselect locale set \$(eselect locale list | grep "en_US.utf8" | awk '{print \$1}' | tr -d '[]')
env-update && source /etc/profile

log "Installing Kernel & Firmware"
emerge --noreplace sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware -q

log "Fstab Configuration"
cat > /etc/fstab <<EOT
UUID=${efi_uuid}   /boot/efi  vfat  umask=0077  0 2
UUID=${root_uuid}  /          ext4  noatime     0 1
EOT

log "Installing Bootloader"
emerge --noreplace sys-boot/grub:2 -q
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck
grub-mkconfig -o /boot/grub/grub.cfg

log "Setting Hostname"
echo "gentoo-machine" > /etc/hostname

log "Finalizing Installation"
emerge --noreplace net-misc/networkmanager sys-apps/dbus sys-auth/elogind -q
rc-update add NetworkManager default
rc-update add dbus default
rc-update add elogind boot

log "Installation Finished Successfully."
EOF

    chmod +x "${MOUNT_POINT}/tmp/install.sh"
    chroot "$MOUNT_POINT" /tmp/install.sh
    rm -f "${MOUNT_POINT}/tmp/install.sh"
}

# --- Execution ---
main() {
    check_env
    prepare_disk
    mount_system
    deploy_stage3
    configure_base
    run_chroot_install
    
    log_step "GENTOO INSTALLATION COMPLETE"
    log_info "You can now reboot your system."
}

main "$@"
