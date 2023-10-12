#! /usr/bin/env bash

set -euo pipefail

: "${PADAVAN_REPO:=https://gitlab.com/a-shevchuk/padavan-ng.git}"
: "${PADAVAN_BRANCH:=master}"
: "${PADAVAN_TOOLCHAIN_URL:=https://gitlab.com/api/v4/projects/a-shevchuk%2Fpadavan-ng/packages/generic/toolchain/latest/toolchain.tzst}"
: "${PADAVAN_IMAGE:=registry.gitlab.com/a-shevchuk/padavan-ng}"
: "${PADAVAN_BUILDER_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/padavan-builder}"
: "${PADAVAN_CONFIG:=}"
: "${PADAVAN_EDITOR:=}"
: "${PADAVAN_DEST:=}"
: "${PADAVAN_REUSE:=}"
: "${PADAVAN_UPDATE:=}"

repo_suffix="${PADAVAN_REPO##*/}"
project="${repo_suffix%.git}"
img_name="padavan-builder"
container="padavan-builder"
disk_img="$container.btrfs"
tmp_dir="$(mktemp -d)"
mnt="$tmp_dir/mnt"
log_file="$tmp_dir/$container.log"

# text decoration utilities
# shellcheck disable=SC2015
{
  normal=$(tput sgr0 ||:)
  bold=$(tput bold ||:)
  info_msg="$(tput setab 33 && tput setaf 231 ||:)$bold" # blue bg, white text
  warn_msg="$(tput setab 220 && tput setaf 16 ||:)$bold" # yellow bg, black text
  accent="$(tput setab 238 && tput setaf 231 ||:)$bold" # gray bg, white text
}

_echo() {
  # unset formatting after output
  echo -e "${*}$normal"
}

_log() {
  type=${1}_msg; shift
  echo -e "$(date +'%Y.%m.%d %H:%M:%S') - $*" &>> "$log_file"

  case "$type" in
    raw*)         _echo "\n $*" ;;&
    info*|warn*)  _echo "\n${!type} $* " ;;
  esac
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

_is_windows() {
  [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]
}

_decide_reuse_disk_img() {
  [[ $PADAVAN_REUSE == true ]] && return 0
  [[ $PADAVAN_REUSE == false ]] && return 1
  _confirm " Reuse it (+) or delete and create a new one (-)?" && return 0
  return 1
}

_decide_reset_and_update_sources() {
  [[ $PADAVAN_UPDATE == true ]] && return 0
  [[ $PADAVAN_UPDATE == false ]] && return 1
  _confirm " Reset and update sources (+) or proceed as is (-)?" && return 0
  return 1
}

_decide_reuse_compiled() {
  [[ $PADAVAN_REUSE == true ]] && return 0
  [[ $PADAVAN_REUSE == false ]] && return 1
  _confirm " Reuse previously compiled files (+) or delete and rebuild (-)?" && return 0
  return 1
}

_decide_delete_disk_img() {
  [[ $PADAVAN_REUSE == true ]] && return 1
  [[ $PADAVAN_REUSE == false ]] && return 0
  _echo "\n If you don't plan to reuse sources, it's ok to delete virtual disk image"
  _confirm " Delete $disk_img disk image?" && return 0
  return 1
}

_satisfy_dependencies() {
  deps=(btrfs-progs podman wget zstd)
  dep_cmds=(mkfs.btrfs podman wget zstd)

  if [[ -z $PADAVAN_EDITOR ]]; then
    deps+=(micro)
    dep_cmds+=(micro)
  fi

  if [[ -z $PADAVAN_CONFIG ]]; then
    deps+=(fzf micro)
    dep_cmds+=(fzf micro)
  fi

  deps_satisfied=0
  for i in "${dep_cmds[@]}"; do
    command -v "$i" &> /dev/null && (( ++deps_satisfied ))
  done

  if (( deps_satisfied < ${#dep_cmds[@]} )); then
    _log info "Installing podman and utilities"
    ID=""
    ID_LIKE=""

    # shellcheck source=/etc/os-release
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

        _confirm " Continue anyway (+) or exit (-)?" || exit 1
        ;;
    esac
  fi
}

_prepare() {
  echo "$(date +'%Y.%m.%d %H:%M:%S') - Starting" > "$log_file"
  _echo "\n${info_msg} Log file: ${normal}${bold} $log_file"
  _echo "$log_follow_reminder"

  _satisfy_dependencies

  _log info "Applying required system settings"

  export STORAGE_DRIVER="overlay"
  export STORAGE_OPTS="overlay.mountopt=volatile"

  # increase open files limit
  ulimit -Sn "$(ulimit -Hn)"
  if (( $(ulimit -Sn) < 4096 )); then
    _log warn "Limit on open files: $(ulimit -Sn). Sometimes that is not enough to build the toolchain"
  fi

  # fix network mtu issues
  wan="$(ip route | grep 'default via' | head -1 | awk '{print $5}' ||:)"
  wan_mtu="$(cat "/sys/class/net/$wan/mtu" ||:)"

  if (( wan_mtu > 1280 )); then
    _log warn "Changing MTU to 1280 to fix various possible network issues"
    _echo     " It will be reverted back aftewards"
    $sudo ip link set "$wan" mtu 1280
  fi

  # if private, podman mounts don't use regular mounts and write to underlying dir instead
  if [[ $(findmnt -no PROPAGATION /) == private ]]; then
    _log warn "Making root mount shared to use compressed virtual disk and save space"
    $sudo mount --make-rshared /
    podman system migrate
  fi

  if _is_windows; then
    _echo "\n${warn_msg} Windows Subsystem for Linux (WSL) has a bug: it doesn't release memory used for file cache"
    _echo " On file intensive operations it can consume all memory and crash"
    _echo " see ${accent} https://github.com/microsoft/WSL/issues/4166 "
    _echo
    _echo " If you experience WSL crashes, you can run a periodic cache cleaner, which should help release memory:"
    _echo " ${accent} sudo sh -c 'while sleep 150; do sync; sysctl -q vm.drop_caches=3; done' "
    _echo " You can then stop it at any time with ${accent} Ctrl + C "
  fi

  if [[ -f $disk_img ]]; then
    _log warn "Existing virtual disk found"
    if _decide_reuse_disk_img; then
      _log info "Reusing existing disk"
    else
      _log info "Deleting existing disk and creating a new one"
      rm -f "$disk_img" &>> "$log_file"
    fi
  fi

  # needs to be separate from previous check, since we could have deleted img there
  if [[ ! -f $disk_img ]]; then
    truncate -s 50G "$disk_img"
    mkfs.btrfs "$disk_img" &>> "$log_file"
  fi

  mkdir -p "$mnt"
  $sudo mount -o noatime,compress=zstd "$disk_img" "$mnt" &>> "$log_file"
  $sudo chown -R "$USER:$USER" "$mnt" &>> "$log_file"
}

ctnr_exec() {
  work_dir=$1; shift
  podman exec -w "$work_dir" "$container" "$@" &>> "$log_file"
}

_start_container() {
  _log info "Starting container to build firmware"
  # `podman pull` needed to support older podman versions,
  # which don't have `podman run --pull newer`, like on Debian 11
  podman pull "$PADAVAN_IMAGE" &>> "$log_file"
  podman run --rm -dt -v "$(realpath "$mnt")":/opt --name "$container" "$PADAVAN_IMAGE" &>> "$log_file"
}

_reset_and_update_sources() {
  pushd "$mnt/$project"
  git reset --hard
  git clean -dfx
  git status
  git pull
  popd
}

_get_prebuilt_toolchain() {
  wget -qO- "$PADAVAN_TOOLCHAIN_URL" | tar -C "$mnt/$project" --zstd -xf -
}

_get_destination_path() {
  local dest="$HOME"

  [[ -n $PADAVAN_DEST ]] && dest="$PADAVAN_DEST"

  if _is_windows; then
    windows_dest="$(powershell.exe "(New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path")"
    dest="$(wslpath "$windows_dest")"
  fi

  echo -n "$dest"
}

_prepare_build_config() {
  _log info "Preparing build config"
  config_selection_header=$(printf "%s\n" "${warn_msg} Select your router model ${normal}" \
                                          " Filter by entering text" \
                                          " Select by mouse or arrow keys" \
                                          " Double click or Enter to confirm")

  configs_glob="$mnt/$project/trunk/configs/templates/*/*config"
  configs_glob_slashes=${configs_glob//[^\/]/} # used to tell fzf how much of the path to skip
  config_file="$(find "$mnt/$project" -type f -path "$configs_glob" | \
                fzf +m -e -d / --with-nth ${#configs_glob_slashes}.. --reverse --no-info --bind=esc:ignore --header-first --header "$config_selection_header")"

  cp "$config_file" "$mnt/$project/trunk/.config"

  _echo "\n${warn_msg} Edit the build config file "
  _echo
  _echo " Firmware features are configured in a text config file using ${accent} CONFIG_FIRMWARE... ${normal} variables"
  _echo " To enable a feature, uncomment its variable by removing ${accent} # ${normal} from the beginning of the line"
  _echo " To disable a feature, comment its variable by putting ${accent} # ${normal} at the beginning of the line"
  _echo
  _echo " Example:"
  _echo " Enable WireGuard:                       │  Disable WireGuard:"
  _echo " ${accent} CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y ${normal}   │  ${accent} #CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y "
  _echo "  ^ no ${accent} # ${normal} at the beginning of the line  │   ^ ${accent} # ${normal} at the beginning of the line"
  _echo
  _echo
  _echo " The text editor supports mouse, clipboard, and common editing and navigation methods:"
  _echo " ${accent} Ctrl + C ${normal}, ${accent} Ctrl + V ${normal}, ${accent} Ctrl + Z ${normal}, ${accent} Ctrl + F ${normal}, etc."
  _echo " See https://github.com/zyedidia/micro/blob/master/runtime/help/defaultkeys.md for hotkey reference"
  _echo
  _echo " All changes are saved automatically and immediately"
  _echo " Close the file with ${accent} Ctrl + Q ${normal} when finished editing"
  _echo
  read -rsp " Press ${warn_msg} Enter ${normal} to start the config editor" < /dev/tty; echo

  if [[ -n $PADAVAN_EDITOR ]]; then
    $PADAVAN_EDITOR "$mnt/$project/trunk/.config"
  else
    micro -autosave 1 -ignorecase 1 -keymenu 1 -scrollbar 1 -filetype shell "$mnt/$project/trunk/.config"
  fi
}

_build_firmware() {
  _log info "Building firmware"
  _echo " This will take a while, usually 10-30 minutes"
  _echo "$log_follow_reminder"
  ctnr_exec "/opt/$project/trunk" ./build_firmware.sh &>> "$log_file"
  _log raw "Done"
}

_copy_artifacts() {
  _echo " Copying to $1"

  mkdir -p "$1"
  cp -v "$mnt/$project"/trunk/images/*trx "$1"

  # shellcheck disable=SC1090
  . <(grep "^CONFIG_FIRMWARE_PRODUCT_ID=" "$mnt/$project/trunk/.config")
  cp -v "$mnt/$project/trunk/.config" "$1/${CONFIG_FIRMWARE_PRODUCT_ID}_$(date '+%Y.%m.%d_%H.%M.%S').config"
}

_handle_exit() {
  if [[ $? != 0 ]]; then
    _echo "\n${warn_msg} Error occured, please check log: ${normal}${bold} $log_file"
    _echo " Failed command: $BASH_COMMAND"
  fi

  set +euo pipefail

  _log warn "Cleaning"
  podman container exists "$container" && podman rm -f "$container" &>> "$log_file"

  if grep -qsE "^\S+ $(realpath "$mnt") " /proc/mounts; then
    _log raw "Unmounting compressed virtual disk"
    $sudo umount "$mnt" &>> "$log_file" || :
  fi

  if [[ -f $disk_img ]]; then
    if _decide_delete_disk_img; then
      _log raw "Deleting virtual disk image"
      rm -rf "$disk_img" &>> "$log_file"
    else
      _log raw "Keeping virtual disk image"
    fi
  fi

  # restore mtu
  if (( ${wan_mtu:-0} > 1280 )); then
    _log raw "Setting back network MTU"
    $sudo ip link set "$wan" mtu "$wan_mtu"
  fi
}

_main() {
  (( $(id -u) > 0 )) && sudo="sudo" || sudo=""

  # shellcheck disable=SC1090
  [[ -f $PADAVAN_BUILDER_CONFIG ]] && . "$PADAVAN_BUILDER_CONFIG"
  log_follow_reminder=" You can follow the log live in another terminal with ${accent} tail -f '$log_file' "

  _prepare
  _start_container

  if [[ -d $mnt/$project ]]; then
    _log warn "Existing source code directory found"

    if _decide_reset_and_update_sources; then
      _log info "Updating"
      _reset_and_update_sources &>> "$log_file"
      _get_prebuilt_toolchain &>> "$log_file"
    elif _decide_reuse_compiled; then
      _log info "Cleaning only neccessary files"
      ctnr_exec "/opt/$project/trunk" make -C user/httpd clean &>> "$log_file"
      ctnr_exec "/opt/$project/trunk" make -C user/rc clean &>> "$log_file"
      ctnr_exec "/opt/$project/trunk" make -C user/shared clean &>> "$log_file"
    else
      _log info "Cleaning"
      ctnr_exec "/opt/$project/trunk" ./clear_tree.sh &>> "$log_file"
    fi
  else
    _log info "Downloading sources and toolchain"
    ctnr_exec "" git clone --depth 1 -b "$PADAVAN_BRANCH" "$PADAVAN_REPO" &>> "$log_file"
    _get_prebuilt_toolchain &>> "$log_file"
  fi

  # use predefined config
  if [[ -n $PADAVAN_CONFIG ]]; then
    cp "$PADAVAN_CONFIG" "$mnt/$project/trunk/.config"
  else
    _prepare_build_config
  fi

  _build_firmware
  _copy_artifacts "$(_get_destination_path)"

  _log info "All done"
}


trap _handle_exit EXIT
_main
