#!/bin/bash

if ! [[ $(id -u) = 0 ]]; then
    echo "This script must be run as root!"
    exit 1
fi

export install_log="$(mktemp -t install_logXXX)"
export red="\033[1;31m"
export green="\033[1;32m"
export cyan="\033[0;36m"
export normal="\033[0m"

title() {
    clear
    echo -ne "${cyan}
################################################################################
#                                                                              #
#   This is Automated Artix Linux Installer for both UEFI and Legacy System    #
#                                                                              #
#                                    By                                        #
#                                                                              #
#                               Hein Oke Soe                                   #
#                                                                              #
################################################################################
${normal}
"
}

start_install() {
    while true; do
        read -srp "Enter root password: " password
        echo
        read -srp "Enter root password again: " password_1
        echo
        check_password root_password ${password} ${password_1}
        [[ $? -eq 0 ]] && break
    done

    read -rp "Enter username: " username
    export username

    while true; do
        read -srp "Enter password for $username: " password
        echo
        read -srp "Enter password for $username again: " password_1
        echo
        check_password user_password ${password} ${password_1}
        [[ $? -eq 0 ]] && break
    done

    read -rp "Enter hostname: " hostname
    export hostname

    choose_disk

    read -rp "Enter boot partition size (e.g. 100M) [default is 512M]: "
    boot_partition_size="${REPLY:-512M}"

    read -rp "Enter root partition size (e.g. 100G) [default is all the remaining space]: "
    root_partition_size="${REPLY}"

    echo -e "\nDo you want to use zram for swap?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case $? in
    0) export use_zram="yes";;
    esac

    echo "Which filesystem do you want to use for root partition?"
    options=("btrfs" "ext4")
    select_option $? 1 "${options[@]}"
    case $? in
    0) export filesystem="btrfs";;
    esac

    echo "Do you want to encrypt root partition?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case $? in
    0) 
        while true; do
            read -srp "Enter password for encrypting root partition: " password
            echo
            read -srp "Enter password for encrypting root partition again: " password_1
            echo
            check_password root_partition_password ${password} ${password_1}
            [[ $? -eq 0 ]] && break
        done
        export encrypt_root="yes";;
    esac

    echo -e "\nWhich init system do you want to use?"
    options=("dinit" "openrc" "runit" "s6")
    select_option $? 1 "${options[@]}"
    case $? in
    0) export init_system="dinit"
        export init_programs=("dinit" "elogind-dinit");;
    1) export init_system="openrc"
        export init_programs=("openrc" "elogind-openrc");;
    2) export init_system="runit"
        export init_programs=("runit" "elogind-runit");;
    3) export init_system="s6"
        export init_programs=("s6-base" "elogind-s6");;
    esac
    
    echo "Do you want to add Archlinux repo support?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case $? in
    0) export arch_repo="yes";;
    esac

    export timezone="$(curl -s --fail https://ipapi.co/timezone)"
    export target_mount_point="/mnt"

    confirm
}

choose_disk() {
    echo -e "\nSelect the disk to install: "
    options=($(lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print "/dev/"$2"("$3")"}'))
    select_option $? 1 "${options[@]}"
    export chosen_disk=${options[$?]}
    export target_device=${chosen_disk%(*}
}

part_disk() {
    log "$1"
    if [[ ! -d /sys/firmware/efi ]]; then
        export is_uefi="no"
    fi
    wipefs -a ${target_device}*
    sfdisk -q --force --delete "${target_device}"
    if [[ "${is_uefi}" == "no" ]]; then
        [[ -b "${target_device}" ]] && echo -e ",${boot_partition_size},0c,*\n,${root_partition_size},L," | sfdisk -q --label dos "${target_device}"
    else
        [[ -b "${target_device}" ]] && echo -e ",${boot_partition_size},U,*\n,${root_partition_size},L," | sfdisk -q --label gpt "${target_device}"
    fi
}

format_disk() {
    log "$1"
    if [[ "${target_device}" =~ "nvme" ]]; then
        boot_partition="${target_device}p1"
        root_partition="${target_device}p2"
    else
        boot_partition="${target_device}1"
        root_partition="${target_device}2"
    fi
    mkfs.fat -F32 "${boot_partition}"
    if [[ "${is_uefi}" == "no" ]]; then
        fatlabel "${boot_partition}" BOOT
    else
        fatlabel "${boot_partition}" EFI
    fi
    if [[ -n ${encrypt_root} ]]; then
        echo "${root_partition_password}" | cryptsetup -q luksFormat ${root_partition}
        export encrypted_uuid=$(cryptsetup luksUUID ${root_partition})
        cryptsetup luksHeaderBackup ${root_partition} --header-backup-file ~/luksheaderbackup
        echo "${root_partition_password}" | cryptsetup luksOpen ${root_partition} root
        if [[ "${filesystem}" == "btrfs" ]]; then
            mkfs.btrfs -L ARTIX /dev/mapper/root
        else
            mkfs.ext4 -L ARTIX /dev/mapper/root
        fi
        root_partition="/dev/mapper/root"
    else
        if [[ "${filesystem}" == "btrfs" ]]; then
            mkfs.btrfs -L ARTIX "${root_partition}"
        else
            mkfs.ext4 -L ARTIX "${root_partition}"
        fi
    fi
}

mount_disk() {
    log "$1"
    mount "${root_partition}" "${target_mount_point}"
    if [[ "${filesystem}" == "btrfs" ]]; then
        btrfs subvolume create "${target_mount_point}/@"
        btrfs subvolume create "${target_mount_point}/@home"
        umount "${target_mount_point}"
        mount -o subvol=@ "${root_partition}" "${target_mount_point}"
        mkdir -p "${target_mount_point}/home"
        mount -o subvol=@home "${root_partition}" "${target_mount_point}/home"
    fi
    mkdir "${target_mount_point}/boot"
    mount "${boot_partition}" "${target_mount_point}/boot"
    [[ -n ${encrypt_root} ]] && cp ~/luksheaderbackup ${target_mount_point}/boot/ || true
}

setup_disk() {
    run_step "Creating Partitions\t\t" "part_disk"
    run_step "Formatting Partitions\t\t" "format_disk"
    run_step "Mounting Partitions\t\t" "mount_disk"
}

confirm() {
    echo -e "Artix Linux is going to be installed on ${chosen_disk}. Do you want to continue?"
    options=("Yes" "No")
    select_option $? 1 "${options[@]}"
    case $? in
    0) setup_disk;;
    1) exit;;
    esac
}

install_base_system() {
    log "$1"
    basestrap "${target_mount_point}" base base-devel linux-lts linux-firmware btrfs-progs cryptsetup-${init_system} "${init_programs[@]}"
    fstabgen -U "${target_mount_point}" >> "${target_mount_point}/etc/fstab"
    [[ -n ${encrypt_root} ]] && echo -e "root\tUUID=${encrypted_uuid}\tnone\tluks" >> "${target_mount_point}/etc/crypttab" || true
}

config_time() {
    log "$1"
    ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    hwclock --systohc
}

config_lang() {
    log "$1"
    echo -e "en_US.UTF-8 UTF-8\nen_US ISO-8859-1" >> /etc/locale.gen
    locale-gen
    echo -e "LANG=en_US.UTF-8\nLC_COLLATE=C" > /etc/locale.conf
}

config_network() {
    log "$1"
    echo "${hostname}" > /etc/hostname
    echo -e "127.0.0.1\tlocalhost" >> /etc/hosts
    echo -e "::1\t\tlocalhost" >> /etc/hosts
    echo -e "127.0.1.1\t${hostname}.localdomain ${hostname}" >> /etc/hosts
    pacman -S --noconfirm --needed connman-${init_system} wpa_supplicant
    case "${init_system}" in
        dinit) ln -s ../connmand /etc/dinit.d/boot.d/;;
        openrc) rc-update add connmand;;
        runit) ln -s /etc/runit/sv/connmand /etc/runit/runsvdir/default;;
        s6) touch /etc/s6/adminsv/default/contents.d/connmand
            s6-db-reload;;
    esac
}

create_user() {
    log "$1"
    echo -e "${root_password}\n${root_password}" | passwd
    useradd -m "${username}"
    echo "${username} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    echo -e "${user_password}\n${user_password}" | passwd "${username}"
    usermod -a -G video,audio,input,power,storage,disk,network "${username}"
}

add_universe_repo() {
    log "$1"
    sed -i "s/^#ParallelDownloads.*$/ParallelDownloads = 4/" /etc/pacman.conf
    echo -e '\n[universe]\nServer = https://universe.artixlinux.org/$arch' >> /etc/pacman.conf
    pacman -Syy
}

add_arch_repo() {
    log "$1"
    pacman -S --noconfirm --needed artix-archlinux-support
    echo -e "\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch" >> /etc/pacman.conf
    echo -e "\n[community]\nInclude = /etc/pacman.d/mirrorlist-arch" >> /etc/pacman.conf
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch" >> /etc/pacman.conf
    pacman-key --populate archlinux
    pacman -Syy
}

setup_bootloader() {
    log "$1"
    if [[ "${is_uefi}" == "no" ]]; then
        pacman -S --noconfirm --needed grub os-prober
        grub-install --recheck "${target_device}"
    else
        pacman -S --noconfirm --needed grub os-prober efibootmgr
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="${hostname}"
    fi
    if [[ -n ${encrypt_root} ]]; then
        sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT.*$/GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=${encrypted_uuid}:root\"/g" /etc/default/grub
        sed -i '/GRUB_ENABLE_CRYPTODISK=y/s/^#//g' /etc/default/grub
    fi
    sed -i '/GRUB_DISABLE_OS_PROBER=false/s/^#//g' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
}

install_microcode() {
    log "$1"
    proc_type=$(lscpu)
    if grep -E "GenuineIntel" <<< "${proc_type}"; then
        pacman -S --noconfirm --needed intel-ucode
    elif grep -E "AuthenticAMD" <<< "${proc_type}"; then
        pacman -S --noconfirm --needed amd-ucode
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

enable_zram() {
    log "$1"
    pacman -S --noconfirm --needed zramen-${init_system}
    case "${init_system}" in
        dinit) ln -s ../zramen /etc/dinit.d/boot.d/;;
        openrc) rc-update add zramen;;
        runit) ln -s /etc/runit/sv/zramen /etc/runit/runsvdir/default;;
        s6) touch /etc/s6/adminsv/default/contents.d/zramen
            s6-db-reload;;
    esac
}

configure_mkinitcpio() {
    log "$1"
    [[ "${filesystem}" == "btrfs" ]] && sed -i 's/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/g' /etc/mkinitcpio.conf || true
    sed -i 's/^HOOKS.*$/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt filesystems fsck)/g' /etc/mkinitcpio.conf
    mkinitcpio -P
}

install_gpu_drivers() {
    log "$1"
    if lspci | grep -E "NVIDIA|GeForce"; then
        pacman -S --noconfirm --needed nvidia
        nvidia-xconfig
    elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
        pacman -S --noconfirm --needed mesa mesa-utils amdvlk vulkan-mesa-layers radeontop libva-mesa-driver mesa-vdpau
    elif lspci | grep 'VGA' | grep -E "Intel"; then
        pacman -S --noconfirm --needed mesa mesa-utils vulkan-intel vulkan-mesa-layers intel-gpu-tools libva-intel-driver
    fi
}

clean() {
    cat ${target_mount_point}/opt/install_log* >> "${install_log}"
    rm ${target_mount_point}/opt/install_log*
    umount -R "${target_mount_point}"
    [[ -n ${encrypt_root} ]] && cryptsetup close "${root_partition}" || true
}

finish() {
    echo -ne "${cyan}
--------------------------------------------------------------------------------
        Installation is done. Please Eject Installation Media and Reboot
--------------------------------------------------------------------------------
${normal}
"
}

check_password() {
    if [[ "$2" == "$3" ]]; then
        export $1="$2"
        return 0
    else
        printf "${red}ERROR: The password does not match. Please try again.${normal}\n"
        return 1
    fi
}

spin() {
    local i=0
    local sp="/-\|"
    local n=${#sp}
    printf " "
    sleep 0.2
    while true; do
        printf "\b${cyan}%s${normal}" "${sp:i++%n:1}"
        sleep 0.2
    done
}

log() {
    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1>>"${install_log}" 2>&1
    echo -e "\n${cyan}${1}${normal}\n"
}

run_step() {
    local msg="$1"
    local func="$2"
    printf "${cyan}${msg}${normal}"
    unshare -fp --kill-child -- bash -c "spin" &
    spinpid=$!
    trap 'kill -9 $spinpid' SIGTERM SIGKILL
    ${func} "${msg}" &>/dev/null
    if [[ $? -eq 0 ]]; then
        kill -9 ${spinpid}
        printf "\b \t\t${cyan}[Done]${normal}\n"
    else
        kill -9 ${spinpid}
        printf "\b \t\t${red}[Failed]${normal}\n"
        printf "\n${red}Sorry! ${msg%%\\*} went wrong. See full log at "
        if ! unshare -U true &>/dev/null ; then
            printf "${target_mount_point}${install_log} ${normal}\n\n"
        else
            printf "${install_log} ${normal}\n\n"
        fi
        exit 1
    fi
}

select_option() {
    # little helpers for terminal print control and key input
    ESC=$( printf "\033")
    cursor_blink_on()   { printf "%s[?25h" "$ESC"; }
    cursor_blink_off()  { printf "%s[?25l" "$ESC"; }
    cursor_to()         { printf "%s[%s;%sH" "$ESC" "$1" "${2:-1}"; }
    print_option()      { printf "%s   %s " "$2" "$1"; }
    print_selected()    { printf "%s  %s[7m %s %s[27m" "$2" "$ESC" "$1" "$ESC"; }
    get_cursor_row()    { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo "${ROW#*[}"; }
    get_cursor_col()    { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo "${COL#*[}"; }
    key_input()         {
        local key
        IFS= read -rsn1 key 2>/dev/null >&2
        if [[ $key = ""      ]]; then echo enter; fi
        if [[ $key = $'\x20' ]]; then echo space; fi
        if [[ $key = "k" ]]; then echo up; fi
        if [[ $key = "j" ]]; then echo down; fi
        if [[ $key = "h" ]]; then echo left; fi
        if [[ $key = "l" ]]; then echo right; fi
        if [[ $key = "a" ]]; then echo all; fi
        if [[ $key = "n" ]]; then echo none; fi
        if [[ $key = $'\x1b' ]]; then
            read -rsn2 key
            if [[ $key = [A || $key = k ]]; then echo up; fi
            if [[ $key = [B || $key = j ]]; then echo down; fi
            if [[ $key = [C || $key = l ]]; then echo right; fi
            if [[ $key = [D || $key = h ]]; then echo left; fi
        fi
    }
    print_options_multicol() {
        # print options by overwriting the last lines
        local curr_col=$1
        local curr_row=$2
        local curr_idx=0

        local idx=0
        local row=0
        local col=0

        curr_idx=$(( curr_col + curr_row * colmax ))

        for option in "${options[@]}"; do

            row=$(( idx / colmax ))
            col=$(( idx - row * colmax ))

            cursor_to $(( startrow + row + 1 )) $(( offset * col + 1 ))
            if [[ $idx -eq $curr_idx ]]; then
                print_selected "$option"
            else
                print_option "$option"
            fi
            ((idx++))
        done
    }

    # initially print empty new lines (scroll down if at bottom of screen)
    for opt; do printf "\n"; done

    # determine current screen position for overwriting the options
    # local return_value=$1
    local lastrow=$(get_cursor_row)
    # local lastcol=$(get_cursor_col)
    local startrow=$(( lastrow - $# ))
    # local startcol=1
    # local lines=$( tput lines )
    local cols=$(tput cols)
    local colmax=$2
    local offset=$(( cols / colmax ))

    # local size=$4
    shift 4

    # ensure cursor and input echoing back on upon a ctrl+c during read -s
    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local active_row=0
    local active_col=0
    while true; do
        print_options_multicol $active_col $active_row
        # user key control
        case $(key_input) in

            enter)  break;;

            up)     (( active_row-- ));
                    if [[ "$active_row" -lt 0 ]]; then active_row=0; fi;;

            down)   (( active_row++ ));
                    if [[ $(( ${#options[@]} % colmax )) -ne 0 ]]; then
                        if [[ "$active_row" -ge $(( ${#options[@]} / colmax )) ]]; then
                            active_row=$(( ${#options[@]} / colmax ));
                        fi
                    else
                        if [[ "$active_row" -ge $(( ${#options[@]} / colmax -1 )) ]]; then
                            active_row=$(( ${#options[@]} / colmax -1 ));
                        fi
                    fi;;

            left)   (( active_col = active_col - 1 ));
                    if [[ "$active_col" -lt 0 ]]; then active_col=0; fi;;

            right)  (( active_col = active_col + 1 ));
                    if [[ "$active_col" -ge "$colmax" ]]; then active_col=$(( colmax - 1 )) ; fi;;

        esac
    done

    # cursor position back to normal
    cursor_to $(( lastrow - $# + ( $# / colmax ) - 1 ))
    printf "\n"
    cursor_blink_on

    return $(( active_col + active_row * colmax ))
}

title
export -f spin
export -f log
export -f run_step
export -f config_time
export -f config_lang
export -f config_network
export -f create_user
export -f add_universe_repo
export -f add_arch_repo
export -f setup_bootloader
export -f install_microcode
export -f enable_zram
export -f configure_mkinitcpio
export -f install_gpu_drivers
start_install
run_step "Installing Base System\t\t" "install_base_system"
artix-chroot "$target_mount_point" bash << '_exit'
install_log="$(mktemp -p /opt -t install_logXXX)"
run_step "Configuring Time\t\t" "config_time"
run_step "Configuring Language\t\t" "config_lang"
run_step "Configuring Network\t\t" "config_network"
run_step "Creating User Account\t\t" "create_user"
run_step "Adding Universe Repo\t\t" "add_universe_repo"
[[ -n ${arch_repo} ]] && run_step "Adding Arch Repo\t\t" "add_arch_repo" || true
run_step "Setting up Bootloader\t\t" "setup_bootloader"
run_step "Installing Microcode\t\t" "install_microcode"
[[ -n ${encrypt_root} || "${filesystem}" == "btrfs" ]] && run_step "Configuring mkinitcpio\t\t" "configure_mkinitcpio" || true
[[ -n ${use_zram} ]] && run_step "Enabling zram\t\t\t" "enable_zram" || true
run_step "Installing GPU Drivers\t\t" "install_gpu_drivers"
_exit
if [[ $? -eq 0 ]]; then
    run_step "Cleaning After Install\t\t" "clean"
    finish
    exit 0
else
    exit 1
fi
