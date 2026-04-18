#!/usr/bin/env bash
# =============================================================================
#  Gentoo Linux 자동 설치 스크립트
#  환경 : amd64 | UEFI/GPT | OpenRC | KDE Plasma | GRUB2 | Swap 없음
#  디스크: /dev/nvme0n1
#  EFI  : /dev/nvme0n1p5
#  ROOT : /dev/nvme0n1p7
#
#  특징
#    - 공식 Gentoo binhost 를 우선 사용해 바이너리 패키지 설치
#    - binpkg 와 충돌하기 쉬운 과도한 USE/KEYWORD 하드코딩 제거
#    - 실패 시 자동 정리, 입력 검증, 서비스 설정 보강
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  {
    echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}▶  $*${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════${NC}"
}

readonly DISK="/dev/nvme0n1"
readonly EFI_PART="${DISK}p5"
readonly ROOT_PART="${DISK}p7"
readonly MOUNT="/mnt/gentoo"
readonly ARCH="amd64"
readonly MIRROR="https://distfiles.gentoo.org"
readonly STAGE3_VARIANT="desktop-openrc"
readonly STAGE3_INDEX="${MIRROR}/releases/${ARCH}/autobuilds/latest-stage3-amd64-${STAGE3_VARIANT}.txt"
readonly STRICT_BINPKG_DEFAULT="no"

INSTALL_FAILED=0
CLEANUP_RUNNING=0

TARGET_HOSTNAME=""
USERNAME=""
ROOT_PASS_HASH=""
USER_PASS_HASH=""
TIMEZONE=""
LOCALE=""
CPU_BRAND=""
GPU_BRAND=""
VIDEO_CARDS=""
STRICT_BINPKG="${STRICT_BINPKG_DEFAULT}"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_hostname() {
    local value="$1"
    [[ "${value}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] && [[ "${value}" != *- ]]
}

validate_username() {
    local value="$1"
    [[ "${value}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ "${value}" != "root" ]]
}

validate_locale() {
    local value="$1"
    [[ "${value}" =~ ^[A-Za-z_]+\.UTF-8$ ]]
}

confirm_yes() {
    local answer="$1"
    [[ "${answer}" == "yes" ]]
}

min_int() {
    local a="$1"
    local b="$2"
    # 입력 검증: 정수인지 확인
    if ! [[ "${a}" =~ ^[0-9]+$ ]] || ! [[ "${b}" =~ ^[0-9]+$ ]]; then
        echo "${b}"
        return
    fi
    if (( a < b )); then
        echo "${a}"
    else
        echo "${b}"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

read_secret_confirm() {
    local prompt="$1"
    local __resultvar="$2"
    local first second

    while :; do
        read -rsp "  ${prompt} : " first
        echo
        [[ -n "${first}" ]] || { warn "빈 값은 사용할 수 없습니다."; continue; }

        read -rsp "  ${prompt} 확인 : " second
        echo

        if [[ "${first}" != "${second}" ]]; then
            warn "입력한 값이 일치하지 않습니다. 다시 입력하세요."
            continue
        fi

        printf -v "${__resultvar}" '%s' "${first}"
        return 0
    done
}

hash_password() {
    local password="$1"
    local hash
    # 비밀번호를 즉시 해시하고 메모리에서 삭제
    hash="$(printf '%s' "${password}" | openssl passwd -6 -stdin)"
    printf '%s' "${hash}"
}

wait_for_device() {
    local device="$1"
    local timeout="${2:-20}"
    local i

    for ((i = 1; i <= timeout; i++)); do
        [[ -b "${device}" ]] && return 0
        sleep 1
    done

    return 1
}

umount_target_if_mounted() {
    local target="$1"
    if findmnt -rn "${target}" >/dev/null 2>&1; then
        umount -lR "${target}" 2>/dev/null || umount -l "${target}" 2>/dev/null || true
    fi
}

umount_source_if_mounted() {
    local source="$1"
    local target=""

    while target="$(findmnt -rn -S "${source}" -o TARGET 2>/dev/null | head -n1)"; [[ -n "${target}" ]]; do
        if ! umount -l "${target}" 2>/dev/null; then
            # umount 실패 시 무한 루프 방지
            break
        fi
    done
}

handle_interrupt() {
    INSTALL_FAILED=1
    echo ""
    fatal "사용자에 의해 중단되었습니다."
}

handle_err() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    local cmd="${2:-unknown}"

    INSTALL_FAILED=1
    trap - ERR
    echo ""
    echo -e "${RED}[ERROR]${NC} ${line_no}번째 줄에서 실패했습니다. (exit=${exit_code})" >&2
    echo -e "${RED}[ERROR]${NC} 실행 명령: ${cmd}" >&2
    exit "${exit_code}"
}

cleanup() {
    [[ "${CLEANUP_RUNNING}" -eq 1 ]] && return 0
    CLEANUP_RUNNING=1

    set +e

    step "마운트 해제 및 임시 파일 정리"

    rm -f "${MOUNT}/install-chroot.sh"

    # 역순으로 마운트 해제 (rslave/rprivate 으로 마운트된 것은 역순 해제 필요)
    umount_target_if_mounted "${MOUNT}/run"
    umount_target_if_mounted "${MOUNT}/dev"
    umount_target_if_mounted "${MOUNT}/sys"
    umount_target_if_mounted "${MOUNT}/proc"
    umount_target_if_mounted "${MOUNT}/boot/efi"
    umount_target_if_mounted "${MOUNT}"

    info "정리 완료"
}

handle_exit() {
    local exit_code="$1"

    cleanup

    if (( exit_code != 0 )); then
        warn "설치가 중단되었습니다. 디스크와 마운트 상태를 한 번 더 확인하세요."
    fi
}

# FIX: single quote 사용 - LINENO 와 BASH_COMMAND 이 지연 평가되도록
trap 'handle_interrupt' INT TERM
trap 'handle_err "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'handle_exit $?' EXIT

set_video_cards() {
    local gpu_brand="$1"
    case "${gpu_brand}" in
        intel)
            VIDEO_CARDS="intel i965 iris"
            ;;
        amd)
            VIDEO_CARDS="amdgpu radeonsi"
            ;;
        nvidia)
            VIDEO_CARDS="nvidia"
            warn "NVIDIA 선택: 오픈소스 binpkg 흐름과 별개로, proprietary 드라이버는 설치 후 추가 작업이 필요할 수 있습니다."
            ;;
        *)
            VIDEO_CARDS=""
            ;;
    esac
}

prompt_user_input() {
    local root_pass=""
    local user_pass=""
    local confirm=""
    local root_hash_tmp=""
    local user_hash_tmp=""

    step "설치 전 필수 정보 입력"
    echo ""

    while :; do
        read -rp "  호스트네임 (예: mygentoo)              : " TARGET_HOSTNAME
        validate_hostname "${TARGET_HOSTNAME}" && break
        warn "호스트네임은 영문/숫자/하이픈만 사용하고, 하이픈으로 끝날 수 없습니다."
    done

    while :; do
        read -rp "  일반 유저 이름                         : " USERNAME
        validate_username "${USERNAME}" && break
        warn "유저 이름은 소문자/숫자/_/- 조합으로 입력하고 root 는 사용할 수 없습니다."
    done

    read_secret_confirm "root 비밀번호" root_pass
    read_secret_confirm "유저 비밀번호" user_pass

    # 비밀번호 해시 생성 후 즉시 원본 삭제
    root_hash_tmp="$(hash_password "${root_pass}")"
    user_hash_tmp="$(hash_password "${user_pass}")"
    ROOT_PASS_HASH="${root_hash_tmp}"
    USER_PASS_HASH="${user_hash_tmp}"
    unset root_pass user_pass root_hash_tmp user_hash_tmp

    while :; do
        read -rp "  타임존 (기본: Asia/Seoul)              : " TIMEZONE
        TIMEZONE="${TIMEZONE:-Asia/Seoul}"
        [[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] && break
        warn "현재 환경에서 확인 가능한 타임존이 아닙니다: ${TIMEZONE}"
    done

    while :; do
        read -rp "  로케일 (기본: en_US.UTF-8)             : " LOCALE
        LOCALE="${LOCALE:-en_US.UTF-8}"
        validate_locale "${LOCALE}" && break
        warn "로케일은 예: en_US.UTF-8 형식으로 입력하세요."
    done

    echo ""
    echo "  CPU 브랜드:"
    echo "    1) Intel    2) AMD"
    read -rp "  선택 [1/2]: " confirm
    case "${confirm}" in
        1) CPU_BRAND="intel" ;;
        2) CPU_BRAND="amd" ;;
        *) fatal "1 또는 2 를 입력하세요." ;;
    esac

    echo ""
    echo "  GPU 종류:"
    echo "    1) Intel (내장/Arc)    2) AMD (Radeon)    3) NVIDIA (GeForce)"
    read -rp "  선택 [1/2/3]: " confirm
    case "${confirm}" in
        1) GPU_BRAND="intel" ;;
        2) GPU_BRAND="amd" ;;
        3) GPU_BRAND="nvidia" ;;
        *) fatal "1, 2, 3 중 하나를 입력하세요." ;;
    esac

    VIDEO_CARDS="$(set_video_cards "${GPU_BRAND}"; echo "${VIDEO_CARDS}")"

    echo ""
    echo -e "${CYAN}────── 설정 요약 ─────────────────────────────────${NC}"
    echo -e "  디스크     : ${DISK}  (EFI: ${EFI_PART} / ROOT: ${ROOT_PART})"
    echo -e "  호스트네임 : ${TARGET_HOSTNAME}"
    echo -e "  유저       : ${USERNAME}"
    echo -e "  타임존     : ${TIMEZONE}"
    echo -e "  로케일     : ${LOCALE}"
    echo -e "  CPU        : ${CPU_BRAND}  /  GPU : ${GPU_BRAND}"
    echo -e "  VIDEO_CARDS: ${VIDEO_CARDS:-<profile default>}"
    echo -e "  binpkg 모드: 공식 Gentoo binhost 우선, 없으면 소스 빌드"
    echo -e "${CYAN}───────────────────────────────────────────────────${NC}"
    echo ""

    read -rp "위 설정으로 진행합니까? (yes/no): " confirm
    confirm_yes "${confirm}" || fatal "사용자가 취소했습니다."
}

check_requirements() {
    local required current_root

    step "실행 환경 점검"

    [[ ${EUID} -eq 0 ]] || fatal "root 권한 필요: sudo bash $0"
    [[ "$(uname -m)" == "x86_64" ]] || fatal "이 스크립트는 amd64(x86_64) 환경에서만 지원합니다."
    [[ -d /sys/firmware/efi/efivars ]] || fatal "UEFI 모드로 부팅된 환경에서만 사용할 수 있습니다."
    [[ -b "${DISK}" ]] || fatal "대상 디스크를 찾을 수 없습니다: ${DISK}"

    current_root="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ -n "${current_root}" && "${current_root}" == "${DISK}"* ]]; then
        fatal "현재 실행 중인 루트 파일시스템이 대상 디스크 (${DISK}) 위에 있습니다. 반드시 라이브 환경에서 실행하세요."
    fi

    required=(
        awk basename blkid cat chroot cp cut findmnt getent grep head lsblk mkdir mount
        nproc openssl partprobe sed sgdisk sha256sum sleep sort tail tar tr umount wget
        mkfs.ext4 mkfs.fat useradd usermod groupadd chpasswd
    )

    for required in "${required[@]}"; do
        command_exists "${required}" || fatal "필수 명령어 없음: ${required}"
    done

    if ! wget -q --spider "${MIRROR}"; then
        fatal "인터넷 연결 실패. 네트워크를 확인하세요: ${MIRROR}"
    fi

    if ! wget -q --spider "${STAGE3_INDEX}"; then
        fatal "Stage3 인덱스에 접근할 수 없습니다: ${STAGE3_INDEX}"
    fi

    info "환경 점검 통과"
}

partition_disk() {
    local confirm=""

    step "기존 파티션 확인: ${DISK}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "${DISK}" || fatal "디스크 정보를 읽지 못했습니다: ${DISK}"

    echo ""
    warn "⚠️  디스크 전체를 다시 파티셔닝하지 않습니다."
    warn "⚠️  대신 아래 두 파티션을 그대로 사용하고, 다음 단계에서 포맷합니다:"
    warn "    EFI  : ${EFI_PART}"
    warn "    ROOT : ${ROOT_PART}"

    # 특정 파티션만 swap 해제 (라이브 환경의 swap 보호)
    if blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null | grep -q "swap"; then
        swapoff "${ROOT_PART}" 2>/dev/null || true
    fi

    umount_source_if_mounted "${EFI_PART}"
    umount_source_if_mounted "${ROOT_PART}"
    umount_target_if_mounted "${MOUNT}"

    [[ -b "${EFI_PART}" ]] || fatal "EFI 파티션이 없습니다: ${EFI_PART}"
    [[ -b "${ROOT_PART}" ]] || fatal "ROOT 파티션이 없습니다: ${ROOT_PART}"

    read -rp "위 파티션 (p5=EFI, p7=ROOT) 으로 계속 진행합니까? (yes/no): " confirm
    confirm_yes "${confirm}" || fatal "파티션 사용 확인이 취소되었습니다."

    if command_exists blkid; then
        info "EFI 현재 타입 : $(blkid -o value -s TYPE "${EFI_PART}" 2>/dev/null || echo unknown)"
        info "ROOT 현재 타입: $(blkid -o value -s TYPE "${ROOT_PART}" 2>/dev/null || echo unknown)"
    fi

    info "파티션 레이아웃:"
    sgdisk --print "${DISK}"
}

format_partitions() {
    step "파티션 포맷"

    [[ -b "${EFI_PART}" ]] || fatal "EFI 파티션이 없습니다: ${EFI_PART}"
    [[ -b "${ROOT_PART}" ]] || fatal "ROOT 파티션이 없습니다: ${ROOT_PART}"

    mkfs.fat -F32 -n EFI "${EFI_PART}"
    mkfs.ext4 -F -L ROOT "${ROOT_PART}"

    info "포맷 완료: ${EFI_PART}(FAT32) / ${ROOT_PART}(ext4)"
}

mount_partitions() {
    step "파티션 마운트"

    mkdir -p "${MOUNT}"
    mount "${ROOT_PART}" "${MOUNT}"
    mkdir -p "${MOUNT}/boot/efi"
    mount "${EFI_PART}" "${MOUNT}/boot/efi"

    info "마운트 완료"
}

install_stage3() {
    local latest_entry=""
    local stage3_url=""
    local stage3_name=""

    step "Stage3 tarball 다운로드 및 압축 해제"

    cd "${MOUNT}"

    # FIX: HTML 파싱 개선 - grep 으로 stage3 파일명 추출
    latest_entry="$(
        wget -qO- "${STAGE3_INDEX}" \
            | grep -oE 'stage3-amd64-[^">[:space:]]+\.tar\.(xz|bz2|gz)' \
            | sort -V | tail -n1 \
            || true
    )"
    [[ -n "${latest_entry}" ]] || fatal "Stage3 경로 조회 실패: ${STAGE3_INDEX}"

    stage3_url="${MIRROR}/releases/${ARCH}/autobuilds/${latest_entry}"
    stage3_name="$(basename "${latest_entry}")"

    info "다운로드: ${stage3_url}"
    wget -c --show-progress "${stage3_url}"
    # .sha256 파일은 작으므로 -c 불필요
    wget --show-progress "${stage3_url}.sha256"

    info "SHA256 무결성 검사"
    # FIX: --ignore-missing 제거 - 해시 파일 조작 감지
    sha256sum --check "${stage3_name}.sha256"

    info "Stage3 압축 해제 중..."
    tar xpf "${stage3_name}" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "${MOUNT}"

    rm -f "${stage3_name}" "${stage3_name}.sha256"
    cd /

    info "Stage3 설치 완료"
}

configure_make_conf() {
    local nproc compile_jobs emerge_jobs binpkg_opts

    step "make.conf 생성"

    nproc="$(nproc)"
    compile_jobs="$(min_int "${nproc}" 8)"
    emerge_jobs="$(min_int "${nproc}" 4)"
    [[ "${compile_jobs}" -ge 1 ]] || compile_jobs=1
    [[ "${emerge_jobs}" -ge 1 ]] || emerge_jobs=1

    binpkg_opts="--getbinpkg --with-bdeps=y --binpkg-respect-use=y"
    [[ "${STRICT_BINPKG}" == "yes" ]] && binpkg_opts="${binpkg_opts} --usepkgonly"

    # FIX: VIDEO_CARDS 가 빈 경우 profile default 사용
    local video_cards_line=""
    if [[ -n "${VIDEO_CARDS}" ]]; then
        video_cards_line="VIDEO_CARDS=\"${VIDEO_CARDS}\""
    else
        video_cards_line="# VIDEO_CARDS 는 profile default 사용"
    fi

    cat > "${MOUNT}/etc/portage/make.conf" <<EOF
# ════════════════════════════════════════════════════════
#  Gentoo make.conf  (자동 생성)
#  amd64 | OpenRC | KDE Plasma | binpkg 우선
# ════════════════════════════════════════════════════════

# 과도한 -march=native, 하드코딩된 Python target, 불필요한 글로벌 USE 는
# 공식 binhost 와 충돌해 소스 빌드를 유발하기 쉬우므로 보수적으로 유지한다.
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C opt-level=2"

MAKEOPTS="-j${compile_jobs} -l${compile_jobs}"
EMERGE_DEFAULT_OPTS="--verbose --jobs=${emerge_jobs} --load-average=${emerge_jobs} ${binpkg_opts}"

CHOST="x86_64-pc-linux-gnu"

INPUT_DEVICES="libinput"
${video_cards_line}

L10N="ko en"
LINGUAS="ko en"
# FIX: 모든 라이선스 수락 대신 자유 라이선스만 허용
ACCEPT_LICENSE="-* @FREE"

GENTOO_MIRRORS="${MIRROR}"
FEATURES="parallel-fetch parallel-install getbinpkg binpkg-request-signature"

GRUB_PLATFORMS="efi-64"
EOF

    info "make.conf 작성 완료 (compile jobs: ${compile_jobs}, emerge jobs: ${emerge_jobs})"
}

configure_portage_dirs() {
    step "Portage 디렉토리 및 기본 설정"

    mkdir -p \
        "${MOUNT}/etc/portage/repos.conf" \
        "${MOUNT}/etc/portage/binrepos.conf" \
        "${MOUNT}/etc/portage/package.use" \
        "${MOUNT}/etc/portage/package.accept_keywords" \
        "${MOUNT}/etc/portage/package.license" \
        "${MOUNT}/etc/portage/package.mask" \
        "${MOUNT}/etc/portage/package.unmask" \
        "${MOUNT}/etc/portage/env"

    if [[ -f "${MOUNT}/usr/share/portage/config/repos.conf" ]]; then
        cp "${MOUNT}/usr/share/portage/config/repos.conf" \
           "${MOUNT}/etc/portage/repos.conf/gentoo.conf"
    fi

    # PipeWire 는 실제 사운드 서버 역할을 하도록 최소한의 package.use 만 지정한다.
    cat > "${MOUNT}/etc/portage/package.use/pipewire" <<'EOF'
media-video/pipewire sound-server pipewire-alsa
EOF

    cp --dereference /etc/resolv.conf "${MOUNT}/etc/resolv.conf"

    info "Portage 기본 디렉토리 설정 완료"
}

mount_chroot_dirs() {
    step "chroot 바인드 마운트"

    mkdir -p "${MOUNT}/proc" "${MOUNT}/sys" "${MOUNT}/dev" "${MOUNT}/run"

    mount --types proc /proc "${MOUNT}/proc"
    # FIX: --make-rslave → --make-rprivate (chroot 내부 마운트가 호스트에 전파되지 않도록)
    mount --rbind /sys "${MOUNT}/sys"
    mount --make-rprivate "${MOUNT}/sys"
    mount --rbind /dev "${MOUNT}/dev"
    mount --make-rprivate "${MOUNT}/dev"
    mount --bind /run "${MOUNT}/run"
    mount --make-rprivate "${MOUNT}/run"

    info "바인드 마운트 완료"
}

write_chroot_script() {
    local root_uuid efi_uuid
    local q_arch q_mirror q_hostname q_username q_root_hash q_user_hash q_timezone q_locale
    local q_cpu q_gpu q_root_uuid q_efi_uuid q_strict

    step "chroot 내부 스크립트 생성"

    root_uuid="$(blkid -s UUID -o value "${ROOT_PART}")" || fatal "ROOT UUID 조회 실패"
    efi_uuid="$(blkid -s UUID -o value "${EFI_PART}")" || fatal "EFI UUID 조회 실패"

    q_arch="$(shell_quote "${ARCH}")"
    q_mirror="$(shell_quote "${MIRROR}")"
    q_hostname="$(shell_quote "${TARGET_HOSTNAME}")"
    q_username="$(shell_quote "${USERNAME}")"
    q_root_hash="$(shell_quote "${ROOT_PASS_HASH}")"
    q_user_hash="$(shell_quote "${USER_PASS_HASH}")"
    q_timezone="$(shell_quote "${TIMEZONE}")"
    q_locale="$(shell_quote "${LOCALE}")"
    q_cpu="$(shell_quote "${CPU_BRAND}")"
    q_gpu="$(shell_quote "${GPU_BRAND}")"
    q_root_uuid="$(shell_quote "${root_uuid}")"
    q_efi_uuid="$(shell_quote "${efi_uuid}")"
    q_strict="$(shell_quote "${STRICT_BINPKG}")"

    cat > "${MOUNT}/install-chroot.sh" <<CHROOT_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\\n\\t'
umask 022

RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
CYAN='\\033[0;36m'
BOLD='\\033[1m'
NC='\\033[0m'

info()  { echo -e "\${GREEN}[INFO]\${NC}  \$*"; }
warn()  { echo -e "\${YELLOW}[WARN]\${NC}  \$*"; }
fatal() { echo -e "\${RED}[ERROR]\${NC} \$*"; exit 1; }
step()  {
    echo -e "\\n\${CYAN}\${BOLD}══════════════════════════════════════════════\${NC}"
    echo -e "\${BLUE}\${BOLD}▶  \$*\${NC}"
    echo -e "\${CYAN}\${BOLD}══════════════════════════════════════════════\${NC}"
}

ARCH=${q_arch}
MIRROR=${q_mirror}
TARGET_HOSTNAME=${q_hostname}
USERNAME=${q_username}
ROOT_PASS_HASH=${q_root_hash}
USER_PASS_HASH=${q_user_hash}
TIMEZONE=${q_timezone}
LOCALE=${q_locale}
CPU_BRAND=${q_cpu}
GPU_BRAND=${q_gpu}
ROOT_UUID=${q_root_uuid}
EFI_UUID=${q_efi_uuid}
STRICT_BINPKG=${q_strict}

append_line_once() {
    local line="\$1"
    local file="\$2"
    grep -Fqx "\$line" "\$file" 2>/dev/null || printf '%s\\n' "\$line" >> "\$file"
}

emerge_bin() {
    local -a opts=(--getbinpkg --with-bdeps=y --binpkg-respect-use=y)
    [[ "\${STRICT_BINPKG}" == "yes" ]] && opts+=(--usepkgonly)
    emerge "\${opts[@]}" "\$@"
}

ensure_group() {
    local group_name="\$1"
    getent group "\${group_name}" >/dev/null 2>&1 || groupadd "\${group_name}"
}

source /etc/profile
export PS1="(chroot) \${PS1}"

step "Portage 트리 동기화"
emerge-webrsync
emerge --sync --quiet

step "프로필 선택 (KDE Plasma / OpenRC)"
# FIX: profile 검색 한 번으로 통합
PROFILE_LINE="\$(
    eselect profile list | grep 'desktop/plasma' | grep -v 'systemd' | awk '/\\(stable\\)/ {print; exit} END {if (!found) print}' | head -n1 || true
)"
if [[ -z "\${PROFILE_LINE}" ]]; then
    PROFILE_LINE="\$(
        eselect profile list | grep 'desktop' | grep -v 'systemd' | awk '/\\(stable\\)/ {print; exit} END {if (!found) print}' | head -n1 || true
    )"
fi
[[ -n "\${PROFILE_LINE}" ]] || fatal "desktop/plasma OpenRC 프로필을 찾을 수 없습니다."

PROFILE_NUM="\$(printf '%s\\n' "\${PROFILE_LINE}" | grep -oE '\\[[0-9]+\\]' | tr -d '[]' | head -n1)"
[[ -n "\${PROFILE_NUM}" ]] || fatal "프로필 번호를 추출하지 못했습니다: \${PROFILE_LINE}"

eselect profile set "\${PROFILE_NUM}"
info "선택된 프로필: \$(eselect profile show)"

step "공식 Gentoo binhost 설정"
mkdir -p /etc/portage/binrepos.conf

PROFILE_REL="\$(eselect profile show)"
PROFILE_REL="\${PROFILE_REL#*/profiles/}"
PROFILE_VERSION="\$(printf '%s\\n' "\${PROFILE_REL}" | grep -oE '[0-9]+\\.[0-9]+' | head -n1 || true)"
BINHOST_URL=""

BINHOST_CANDIDATES=(
    "\${MIRROR}/releases/\${ARCH}/binpackages/\${PROFILE_REL}/x86-64"
)
if [[ -n "\${PROFILE_VERSION}" ]]; then
    BINHOST_CANDIDATES+=("\${MIRROR}/releases/\${ARCH}/binpackages/\${PROFILE_VERSION}/x86-64")
fi

for candidate in "\${BINHOST_CANDIDATES[@]}"; do
    [[ -n "\${candidate}" ]] || continue
    if wget -q --spider "\${candidate}/Packages"; then
        BINHOST_URL="\${candidate}/"
        break
    fi
done

if [[ -n "\${BINHOST_URL}" ]]; then
    cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[binhost]
priority = 9999
sync-uri = \${BINHOST_URL}
EOF
    info "binhost 설정: \${BINHOST_URL}"
else
    warn "binhost URL 자동 감지 실패. stage3 기본 binrepos.conf 가 있으면 그대로 사용합니다."
fi

if command -v getuto >/dev/null 2>&1; then
    getuto || warn "getuto 실행에 실패했습니다. Portage 자동 호출에 맡깁니다."
fi

step "CPU 플래그 감지"
emerge_bin --oneshot app-portage/cpuid2cpuflags
CPU_FLAGS="\$(cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: //')"
sed -i '/^CPU_FLAGS_X86=/d' /etc/portage/make.conf
printf '\\nCPU_FLAGS_X86="%s"\\n' "\${CPU_FLAGS}" >> /etc/portage/make.conf
info "CPU_FLAGS_X86=\\"\${CPU_FLAGS}\\""

mkdir -p /etc/portage/package.license
append_line_once "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" /etc/portage/package.license/firmware
if [[ "\${CPU_BRAND}" == "intel" ]]; then
    append_line_once "sys-firmware/intel-microcode intel-ucode" /etc/portage/package.license/firmware
fi

step "타임존 설정: \${TIMEZONE}"
[[ -e "/usr/share/zoneinfo/\${TIMEZONE}" ]] || fatal "존재하지 않는 타임존입니다: \${TIMEZONE}"
echo "\${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data

step "로케일 생성"
# FIX: 중복 로케일 제거
{
    echo "en_US.UTF-8 UTF-8"
    echo "ko_KR.UTF-8 UTF-8"
    echo "\${LOCALE} UTF-8"
} | sort -u > /etc/locale.gen
locale-gen

LOCALE_NUM="\$(eselect locale list | grep -F "\${LOCALE}" | head -n1 | grep -oE '\\[[0-9]+\\]' | tr -d '[]' || true)"
if [[ -n "\${LOCALE_NUM}" ]]; then
    eselect locale set "\${LOCALE_NUM}"
else
    warn "로케일 '\${LOCALE}' 을 찾지 못했습니다. 기본값을 유지합니다."
fi
env-update
source /etc/profile

step "@world 업데이트 (binpkg 우선)"
emerge_bin --update --deep --newuse @world

step "펌웨어 설치"
emerge_bin --noreplace sys-kernel/linux-firmware
if [[ "\${CPU_BRAND}" == "intel" ]]; then
    emerge_bin --noreplace sys-firmware/intel-microcode
fi

step "커널 설치: gentoo-kernel-bin"
emerge_bin --noreplace sys-kernel/gentoo-kernel-bin
KERNEL_IMAGE="\$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)"
[[ -n "\${KERNEL_IMAGE}" ]] || fatal "설치된 커널 이미지를 찾을 수 없습니다."
info "커널: \${KERNEL_IMAGE}"

step "/etc/fstab 설정"
cat > /etc/fstab <<EOF
# <file system>  <mount point>  <type>  <options>         <dump> <pass>
UUID=\${EFI_UUID}   /boot/efi  vfat  umask=0077          0 2
UUID=\${ROOT_UUID}  /          ext4  defaults,noatime    0 1
EOF

step "호스트네임 및 hosts 설정"
echo "\${TARGET_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   \${TARGET_HOSTNAME}.localdomain  \${TARGET_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

step "기본 시스템 패키지 설치"
emerge_bin --noreplace \\
    sys-auth/elogind             \\
    sys-auth/polkit              \\
    sys-auth/rtkit               \\
    sys-apps/dbus                \\
    net-misc/networkmanager      \\
    net-wireless/wpa_supplicant  \\
    app-admin/sysklogd           \\
    sys-process/cronie           \\
    app-shells/bash-completion   \\
    app-editors/nano             \\
    app-admin/sudo               \\
    dev-vcs/git                  \\
    app-portage/gentoolkit       \\
    app-portage/eix              \\
    sys-apps/mlocate             \\
    sys-apps/pciutils            \\
    sys-apps/usbutils

step "부트로더 설치"
emerge_bin --noreplace sys-boot/grub sys-boot/os-prober

cat > /etc/default/grub <<EOF
GRUB_DISTRIBUTOR="Gentoo"
GRUB_DEFAULT=0
GRUB_TIMEOUT=8
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=false
EOF

# FIX: EFI 변수 접근 가능 여부 확인 후 grub-install 실행
if [[ -d /sys/firmware/efi/efivars ]]; then
    grub-install \\
        --target=x86_64-efi \\
        --efi-directory=/boot/efi \\
        --bootloader-id=Gentoo \\
        --recheck
else
    warn "EFI 변수에 접근할 수 없습니다. 라이브 환경이 UEFI 모드로 부팅되지 않았을 수 있습니다."
    fatal "grub-install 를 수동으로 실행하세요: grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo"
fi

os-prober || warn "os-prober 가 다른 OS 를 찾지 못했습니다. 멀티부팅이면 재부팅 후 grub-mkconfig 를 다시 실행하세요."
grub-mkconfig -o /boot/grub/grub.cfg

step "KDE Plasma 및 데스크톱 패키지 설치"
emerge_bin --noreplace \\
    gui-libs/display-manager-init \\
    kde-plasma/plasma-meta        \\
    kde-plasma/sddm-kcm           \\
    x11-misc/sddm                 \\
    kde-apps/konsole              \\
    kde-apps/dolphin              \\
    kde-apps/kate                 \\
    kde-apps/ark                  \\
    kde-apps/spectacle            \\
    kde-apps/gwenview             \\
    kde-apps/okular               \\
    kde-apps/kcalc                \\
    www-client/google-chrome      \\
    media-video/vlc               \\
    media-video/pipewire          \\
    media-video/wireplumber       \\
    app-misc/discord              \\
    app-editors/visual-studio-code-bin \\
    games-util/steam              \\
    app-i18n/ibus                 \\
    app-i18n/ibus-hangul          \\
    media-fonts/noto              \\
    media-fonts/noto-cjk          \\
    media-fonts/nanum

step "디스플레이 매니저 설정"
cat > /etc/conf.d/display-manager <<EOF
CHECKVT=7
DISPLAYMANAGER="sddm"
EOF

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/kde.conf <<EOF
[Theme]
Current=breeze
EOF

if id -u sddm >/dev/null 2>&1; then
    usermod --append --groups video sddm || true
fi

step "IBus 입력기 환경 설정"
mkdir -p /etc/env.d
cat > /etc/env.d/99inputmethod <<EOF
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF
env-update

step "계정 설정"
printf 'root:%s\\n' "\${ROOT_PASS_HASH}" | chpasswd -e

for group_name in wheel audio video usb cdrom input; do
    ensure_group "\${group_name}"
done
USER_GROUPS="wheel,audio,video,usb,cdrom,input"

if id -u "\${USERNAME}" >/dev/null 2>&1; then
    usermod --append --groups "\${USER_GROUPS}" "\${USERNAME}"
else
    useradd --create-home --shell /bin/bash --groups "\${USER_GROUPS}" "\${USERNAME}"
fi
printf '%s:%s\\n' "\${USERNAME}" "\${USER_PASS_HASH}" | chpasswd -e

# FIX: sudoers.d 디렉토리 권한 0700 으로 설정
install -d -m 0700 /etc/sudoers.d
cat > /etc/sudoers.d/wheel <<EOF
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/wheel

step "OpenRC 서비스 등록"
rc-update add elogind boot
rc-update add dbus default
rc-update add NetworkManager default
rc-update add sysklogd default
rc-update add cronie default
rc-update add display-manager default

step "서비스 현황"
rc-update show default || true

echo ""
echo -e "\${GREEN}\${BOLD}╔══════════════════════════════════════════════╗\${NC}"
echo -e "\${GREEN}\${BOLD}║  ✅  chroot 내부 설치 완료                   ║\${NC}"
echo -e "\${GREEN}\${BOLD}╚══════════════════════════════════════════════╝\${NC}"
CHROOT_SCRIPT

    chmod +x "${MOUNT}/install-chroot.sh"
    info "chroot 스크립트 생성 완료"
}

run_chroot() {
    step "chroot 진입"

    if [[ -n "${TERM:-}" ]]; then
        chroot "${MOUNT}" /usr/bin/env -i \
            HOME=/root \
            TERM="${TERM}" \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/bash /install-chroot.sh
    else
        chroot "${MOUNT}" /usr/bin/env -i \
            HOME=/root \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/bash /install-chroot.sh
    fi
}

print_finish() {
    echo ""
    echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   🎉  Gentoo Linux 설치 완료!                              ║${NC}"
    echo -e "${GREEN}${BOLD}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}║  1. reboot                                                ║${NC}"
    echo -e "${GREEN}${BOLD}║  2. GRUB 메뉴에서 Gentoo GNU/Linux 선택                   ║${NC}"
    echo -e "${GREEN}${BOLD}║  3. SDDM 에서 KDE Plasma (Wayland/X11) 로그인             ║${NC}"
    echo -e "${GREEN}${BOLD}║                                                           ║${NC}"
    echo -e "${GREEN}${BOLD}║  참고                                                     ║${NC}"
    echo -e "${GREEN}${BOLD}║  - Portage 는 공식 binhost 를 우선 사용합니다.            ║${NC}"
    echo -e "${GREEN}${BOLD}║  - 정확히 일치하는 binpkg 가 없으면 일부는 소스 빌드될 수║${NC}"
    echo -e "${GREEN}${BOLD}║    있습니다.                                              ║${NC}"
    echo -e "${GREEN}${BOLD}║  - 업데이트: emerge -uDNav @world                         ║${NC}"
    echo -e "${GREEN}${BOLD}║  - 패키지 검색: eix-update && eix <패키지명>              ║${NC}"
    echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"

    if [[ "${GPU_BRAND}" == "nvidia" ]]; then
        echo ""
        warn "NVIDIA 선택됨: Wayland 안정화를 위해 설치 후 proprietary 드라이버와 nvidia-drm.modeset=1 설정이 추가로 필요할 수 있습니다."
    fi
}

main() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║   Gentoo Linux 자동 설치 스크립트                         ║"
    echo "  ║   amd64 | UEFI/GPT | OpenRC | KDE Plasma | binpkg 우선    ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_requirements
    prompt_user_input
    partition_disk
    format_partitions
    mount_partitions
    install_stage3
    configure_make_conf
    configure_portage_dirs
    mount_chroot_dirs
    write_chroot_script
    run_chroot
    print_finish
}

main "$@"
