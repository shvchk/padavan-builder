#! /usr/bin/env bash

set -euo pipefail

dest_dir="$HOME"
win_dest_dir="/mnt/c/Users/Public/Downloads/padavan"
repo_url="${1:-${PADAVAN_REPO:-https://gitlab.com/a-shevchuk/padavan-ng}}"
branch="${2:-${PADAVAN_BRANCH:-master}}"
img="registry.gitlab.com/a-shevchuk/padavan-ng"
img_name="padavan-builder"
container="padavan-builder"
disk_img="${container}.btrfs"
toolchain_url="${repo_url}/-/jobs/5199075640/artifacts/raw/toolchain.tzst"

deps=(btrfs-progs fzf micro podman wget zstd)
dep_cmds=(mkfs.btrfs fzf micro podman wget zstd)

# text decoration utilities
normal=$(tput sgr0 ||:)
bold=$(tput bold ||:)
info_msg="$(tput setab 33 && tput setaf 231 ||:)${bold}" # blue bg, white text
warn_msg="$(tput setab 220 && tput setaf 16 ||:)${bold}" # yellow bg, black text
accent="$(tput setab 238 && tput setaf 231 ||:)${bold}" # gray bg, white text

tmp_dir="$(mktemp -d)"
mnt="${tmp_dir}/mnt"
log_file="${tmp_dir}/${container}.log"
log_follow_reminder=" You can follow the log live in another terminal with ${accent} tail -f '$log_file' "

(( $(id -u) > 0 )) && sudo="sudo" || sudo=""

# helper functions

_echo() {
  # unset formatting after output
  echo -e "${*}${normal}"
}

_log() {
  type=${1}_msg; shift
  echo -e "$(date +'%Y.%m.%d %H:%M:%S') - $*" &>> "$log_file"

  case "$type" in
    raw*)         _echo "\n $*" ;;&
    info*|warn*)  _echo "\n${!type} $* " ;;
  esac
}

_handle_exit() {
  set +euo pipefail

  if [[ $? != 0 ]]; then
    _echo "\n${warn_msg} Error occured, please check log: ${normal}${bold} ${log_file}"
    _echo " Failed command: $BASH_COMMAND"
  fi

  _log warn "Cleaning"
  podman container exists "$container" && podman rm -f "$container" &>> "$log_file"

  if grep -qsE "^\S+ $(realpath $mnt) " /proc/mounts; then
    _log raw "Unmounting compressed virtual disk"
    $sudo umount "$mnt" &>> "$log_file" || :
  fi

  if [[ -f $disk_img ]]; then
    _echo "\n If you don't plan to reuse it, it's ok to delete virtual disk image"
    _confirm " Delete $disk_img disk image?" && rm -rf "$disk_img" "$mnt" &>> "$log_file"
  fi

  # restore mtu
  if [[ -v $wan_mtu ]] && (( wan_mtu > 1280 )); then
    _log raw "Setting back network MTU"
    $sudo ip link set "$wan" mtu "$wan_mtu"
  fi
}

_confirm() {
  while echo; do
    # `< /dev/tty` is required to be able to run via pipe: cat x.sh | bash
    read -rp "$* [ + or - ]: " confirmation < /dev/tty || { echo "No tty"; exit 1; }
    case "$confirmation" in
      "+") return 0 ;;
      "-") return 1 ;;
    esac
  done
}


# main functions

_prepare() {
  echo "$(date +'%Y.%m.%d %H:%M:%S') - Starting" > "$log_file"
  _echo "\n${info_msg} Log file: ${normal}${bold} ${log_file}"
  _echo "$log_follow_reminder"

  deps_satisfied=0
  for i in "${dep_cmds[@]}"; do
    command -v "$i" &> /dev/null && (( ++deps_satisfied ))
  done

  if (( deps_satisfied < ${#dep_cmds[@]} )); then
    _log info "Installing podman and utilities"
    ID=""
    ID_LIKE=""

    [[ -f /etc/os-release ]] && . <(grep "^ID" /etc/os-release)

    case "$ID $ID_LIKE" in
      *alpine*)
        $sudo apk add --no-cache --no-interactive "${deps[@]}" &>> "$log_file" ;;

      *arch*)
        $sudo pacman -Syu --noconfirm "${deps[@]}" &>> "$log_file" ;;

      *debian*|*ubuntu*)
        $sudo apt update &>> "$log_file"
        $sudo apt install -y "${deps[@]}" &>> "$log_file" ;;

      *fedora*|*rhel*)
        $sudo dnf install -y "${deps[@]}" &>> "$log_file" ;;

      *suse*)
        deps=("${deps[@]/btrfs-progs/btrfsprogs}")
        deps=("${deps[@]/micro/micro-editor}")
        $sudo zypper --non-interactive install "${deps[@]}" &>> "$log_file" ;;

      *)
        _log warn "Unknown OS, can't install dependencies"
        _echo     " Please install these packages manually:"
        _echo     " ${deps[*]}"

        _confirm "Continue anyway (+) or exit (-)?" || exit 1
        ;;
    esac
  fi

  _log info "Applying required system settings"

  export STORAGE_DRIVER="overlay"
  export STORAGE_OPTS="overlay.mountopt=volatile"

  ulimit -Sn "$(ulimit -Hn)"
  if (( $(ulimit -Sn) < 4096 )); then
    _log warn "Limit on open files: $(ulimit -Sn). Sometimes that is not enough to build the toolchain"
  fi

  # fix network mtu issues
  wan="$(ip route | grep 'default via' | head -1 | awk '{print $5}' ||:)"
  wan_mtu="$(cat "/sys/class/net/${wan}/mtu" ||:)"

  if (( wan_mtu > 1280 )); then
    _log warn "Changing MTU to 1280 to fix various possible network issues"
    _echo     "It will be reverted back aftewards"
    $sudo ip link set "$wan" mtu 1280
  fi

  # if private, podman mounts don't use regular mounts and write to underlying dir instead
  if [[ $(findmnt -no PROPAGATION /) == private ]]; then
    _log warn "Making root mount shared to use compressed virtual disk and save space"
    $sudo mount --make-rshared /
  fi

  mkdir -p "$mnt"

  if [[ -f $disk_img ]]; then
    _log warn "Existing virtual disk found"
    _confirm " Reuse it (+) or delete and make a new one (-)?" || rm -f "$disk_img"
  fi

  # needs to be separate from previous check, since we could have deleted img there
  if [[ ! -f $disk_img ]]; then
    truncate -s 50G "$disk_img"
    mkfs.btrfs "$disk_img" &>> "$log_file"
  fi

  $sudo mount -o noatime,compress=zstd "$disk_img" "$mnt" &>> "$log_file"
  $sudo chown -R $USER:$USER "$mnt" &>> "$log_file"
}

ctnr_exec() {
  work_dir=$1; shift
  podman exec -w "$work_dir" "$container" "$@" &>> "$log_file"
}

_start_container() {
  _log info "Starting container to build firmware"
  # `podman pull` needed to support older podman versions,
  # which don't have `podman run --pull newer`, like on Debian 11
  podman pull "$img" &>> "$log_file"
  podman run --rm -dt -v "$(realpath "$mnt")":/opt --name "$container" "$img" &>> "$log_file"
}

_clone_repo_sparse() {
  _log info "Cloning $repo_url ($branch)"
  # sparse checkout
  ctnr_exec '' git clone -vn --depth 1 --filter tree:0 -b "$branch" "$repo_url" &>> "$log_file"
  ctnr_exec /opt/padavan-ng git sparse-checkout set --no-cone "$@" &>> "$log_file"
  ctnr_exec /opt/padavan-ng git checkout &>> "$log_file"
}

_prepare_build_config() {
  build_config="${tmp_dir}/padavan-build.config"
  config_selection_header=$(printf "%s\n" "${warn_msg} Select your router model ${normal}" \
                                          " Filter by entering text" \
                                          " Select by mouse or arrow keys" \
                                          " Double click or Enter to confirm")

  config_file="$(find "${mnt}"/padavan-ng/trunk/configs/templates/*/*config | \
                fzf +m -e -d / --with-nth 6.. --reverse --no-info --bind=esc:ignore --header-first --header "$config_selection_header")"

  cp "$config_file" "$build_config"

  _echo "\n${warn_msg} Edit the build config file "
  _echo
  _echo " Firmware features are configured in a text config file using ${accent} CONFIG_FIRMWARE... ${normal} variables"
  _echo " To enable a feature, uncomment its variable by removing ${accent} # ${normal} from the beginning of the line"
  _echo " To disable a feature, comment its variable by putting ${accent} # ${normal} at the beginning of the line"
  _echo
  _echo " Example:"
  _echo " Enable WireGuard:"
  _echo " ${accent} CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y "
  _echo "  ^ no ${accent} # ${normal} at the beginning of the line"
  _echo
  _echo " Disable WireGuard:"
  _echo " ${accent} #CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y "
  _echo "  ^ ${accent} # ${normal} at the beginning of the line"
  _echo
  _echo
  _echo " The text editor supports mouse, clipboard, and common editing and navigation methods:"
  _echo " ${accent} Ctrl + C ${normal}, ${accent} Ctrl + V ${normal}, ${accent} Ctrl + Z ${normal}, ${accent} Ctrl + F ${normal}, etc."
  _echo " See https://github.com/zyedidia/micro/blob/master/runtime/help/defaultkeys.md for hotkey reference"
  _echo
  _echo " All changes are saved automatically and immediately"
  _echo " Close the file with ${accent} Ctrl + Q ${normal} when finished editing"
  _echo
  read -rsn1 -p "${accent} Press any key to start the config editor ${normal}" < /dev/tty; echo

  micro -autosave 1 -ignorecase 1 -keymenu 1 -scrollbar 1 -filetype shell "$build_config"
  cp "$build_config" "${mnt}/padavan-ng/trunk/.config"

  _echo " Build config backup: $build_config"
}

_build_firmware() {
  _log info "Building firmware"
  _echo " This will take a while, usually 10-30 minutes"
  _echo "$log_follow_reminder"
  ctnr_exec /opt/padavan-ng/trunk ./clear_tree.sh &>> "$log_file"
  ctnr_exec /opt/padavan-ng/trunk ./build_firmware.sh &>> "$log_file"
  _log raw "Done"
}

_copy_firmware_to_host() {
  _echo " Copying firmware to $dest_dir"

  # if we are in WSL, $dest_dir is $win_dest_dir
  [[ -f /proc/sys/fs/binfmt_misc/WSLInterop && -w $win_dest_dir ]] && dest_dir=$win_dest_dir

  mkdir -p "$dest_dir"
  cp "${mnt}"/padavan-ng/trunk/images/*trx "$dest_dir"

  . <(grep "^CONFIG_FIRMWARE_PRODUCT_ID=" "${mnt}/padavan-ng/trunk/.config")
  cp "${mnt}/padavan-ng/trunk/.config" "${dest_dir}/${CONFIG_FIRMWARE_PRODUCT_ID}_$(date '+%Y.%m.%d_%H.%M.%S').config"
}


# main

trap _handle_exit EXIT

_prepare

_start_container

if [[ -d "${mnt}/padavan-ng" ]]; then
  _log warn "Existing sources directory found"
  _confirm " Reuse it (+) or delete and start from scratch (-)?" || rm -f "${mnt}/padavan-ng"
fi

if [[ ! -d "${mnt}/padavan-ng" ]]; then
  _clone_repo_sparse /trunk

  # get prebuilt toolchain
  wget -qO- "$toolchain_url" | tar -C "${mnt}/padavan-ng" --zstd -xf -
fi

_prepare_build_config
_build_firmware
_copy_firmware_to_host

_log info "All done"
