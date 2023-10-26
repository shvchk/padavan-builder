#! /usr/bin/env bash

set -euo pipefail

: "${PADAVAN_REPO:=https://gitlab.com/hadzhioglu/padavan-ng.git}"
: "${PADAVAN_BRANCH:=master}"
: "${PADAVAN_CONTAINERFILE:=${PADAVAN_REPO%.git}/raw/$PADAVAN_BRANCH/Dockerfile}"
: "${PADAVAN_TOOLCHAIN_URL:=https://gitlab.com/api/v4/projects/hadzhioglu%2Fpadavan-ng/packages/generic/toolchain/latest/toolchain.tzst}"
: "${PADAVAN_IMAGE:=registry.gitlab.com/hadzhioglu/padavan-ng}"
: "${PADAVAN_BUILDER_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/padavan-builder}"
: "${PADAVAN_BUILD_ALL_LOCALLY:=}"
: "${PADAVAN_BUILD_CONTAINER:=}"
: "${PADAVAN_BUILD_TOOLCHAIN:=}"
: "${PADAVAN_PAUSE_BEFORE_BUILD:=}"
: "${PADAVAN_CONFIG:=}"
: "${PADAVAN_EDITOR:=}"
: "${PADAVAN_DEST:=}"
: "${PADAVAN_REUSE:=}"
: "${PADAVAN_UPDATE:=}"

repo_suffix="${PADAVAN_REPO##*/}"
project="${repo_suffix%.git}"
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
  err_msg="$(tput setab 160 && tput setaf 231 ||:)$bold" # red bg, white text
  accent="$(tput setab 238 && tput setaf 231 ||:)$bold" # gray bg, white text
}

_echo() {
  # unset formatting after output
  echo -e "${*}$normal"
}

log() {
  type=${1}_msg; shift
  echo -e "$(date +'%Y.%m.%d %H:%M:%S') - $*" &>> "$log_file"

  case "$type" in
    raw*)              _echo "\n $*"          ;;
    info*|warn*|err*)  _echo "\n${!type} $* " ;;
  esac
}

confirm() {
  while echo; do
    # `< /dev/tty` is required to be able to run via pipe: cat x.sh | bash
    read -rp "$* [ + or - ]: " confirmation < /dev/tty || { echo "No tty"; exit 1; }
    case "$confirmation" in
      "+") return 0 ;;
      "-") return 1 ;;
    esac
  done
}

is_windows() {
  [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]
}

decide_reuse_disk_img() {
  [[ $PADAVAN_REUSE == true ]] && return 0
  [[ $PADAVAN_REUSE == false ]] && return 1
  confirm " Reuse it (+) or delete and create a new one (-)?" && return 0
  return 1
}

decide_reset_and_update_sources() {
  [[ $PADAVAN_UPDATE == true ]] && return 0
  [[ $PADAVAN_UPDATE == false ]] && return 1
  confirm " Reset and update sources (+) or proceed as is (-)?" && return 0
  return 1
}

decide_reuse_compiled() {
  [[ $PADAVAN_REUSE == true ]] && return 0
  [[ $PADAVAN_REUSE == false ]] && return 1
  confirm " Reuse previously compiled files (+) or delete and rebuild (-)?" && return 0
  return 1
}

decide_delete_disk_img() {
  [[ $PADAVAN_REUSE == true ]] && return 1
  [[ $PADAVAN_REUSE == false ]] && return 0
  _echo "\n If you don't plan to reuse sources, it's ok to delete virtual disk image"
  confirm " Delete $disk_img disk image?" && return 0
  return 1
}

satisfy_dependencies() {
  deps=(btrfs-progs coreutils gawk grep podman wget zstd)
  dep_cmds=(awk grep mkfs.btrfs podman wget zstd)

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
    log info "Installing podman and utilities"
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
        log warn "Unknown OS, can't install dependencies"
        _echo     " Please install these packages manually:"
        _echo     " ${deps[*]}"

        confirm " Continue anyway (+) or exit (-)?" || exit 1
        ;;
    esac
  fi
}

prepare() {
  echo "$(date +'%Y.%m.%d %H:%M:%S') - Starting" > "$log_file"
  _echo "\n${info_msg} Log file: ${normal}${bold} $log_file"
  _echo "$log_follow_reminder"

  satisfy_dependencies

  log info "Applying required system settings"

  export STORAGE_DRIVER="overlay"
  export STORAGE_OPTS="overlay.mountopt=volatile"

  # increase open files limit
  ulimit -Sn "$(ulimit -Hn)"
  if (( $(ulimit -Sn) < 4096 )); then
    log warn "Limit on open files: $(ulimit -Sn). Sometimes that is not enough to build the toolchain"
  fi

  # fix network mtu issues
  wan="$(ip route | grep 'default via' | head -1 | awk '{print $5}' ||:)"
  wan_mtu="$(cat "/sys/class/net/$wan/mtu" ||:)"

  if (( wan_mtu > 1280 )); then
    log warn "Changing MTU to 1280 to fix various possible network issues"
    _echo     " It will be reverted back aftewards"
    $sudo ip link set "$wan" mtu 1280
  fi

  # if private, podman mounts don't use regular mounts and write to underlying dir instead
  if [[ $(findmnt -no PROPAGATION /) == private ]]; then
    log warn "Making root mount shared to use compressed virtual disk and save space"
    $sudo mount --make-rshared /
    podman system migrate
  fi

  if is_windows; then
    _echo "\n${warn_msg} Windows Subsystem for Linux (WSL) has a bug: it doesn't release memory used for file cache"
    _echo " On file intensive operations it can consume all memory and crash"
    _echo " see ${accent} https://github.com/microsoft/WSL/issues/4166 "
    _echo
    _echo " If you experience WSL crashes, you can run a periodic cache cleaner, which should help release memory:"
    _echo " ${accent} sudo sh -c 'while sleep 150; do sync; sysctl -q vm.drop_caches=3; done' "
    _echo " You can then stop it at any time with ${accent} Ctrl + C "
  fi

  if [[ -f $disk_img ]]; then
    log warn "Existing virtual disk found"
    if decide_reuse_disk_img; then
      log info "Reusing existing disk"
    else
      log info "Deleting existing disk and creating a new one"
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

build_container() {
  podman rmi -f "$container"
  podman build -t "$container" -f "$PADAVAN_CONTAINERFILE" .
  PADAVAN_IMAGE="localhost/$container"
}

ctnr_exec() {
  work_dir=$1; shift
  podman exec -w "$work_dir" "$container" "$@"
}

start_container() {
  log info "Starting container to build firmware"
  # `podman pull` needed to support older podman versions,
  # which don't have `podman run --pull newer`, like on Debian 11
  podman pull "$PADAVAN_IMAGE" &>> "$log_file"
  podman run --rm -dt -v "$(realpath "$mnt")":/opt --name "$container" "$PADAVAN_IMAGE" &>> "$log_file"
}

reset_and_update_sources() {
  ctnr_exec "/opt/$project" git reset --hard
  ctnr_exec "/opt/$project" git clean -dfx
  ctnr_exec "/opt/$project" git status
  ctnr_exec "/opt/$project" git pull
}

build_toolchain() {
  log info "Building toolchain"
  _echo " This will take a while, usually 20-60 minutes"
  _echo "$log_follow_reminder"
  ctnr_exec "/opt/$project/toolchain" ./clean_sources.sh &>> "$log_file"
  ctnr_exec "/opt/$project/toolchain" ./build_toolchain.sh &>> "$log_file"
  log raw "Done"
}

get_prebuilt_toolchain() {
  wget -qO- "$PADAVAN_TOOLCHAIN_URL" | tar -C "$mnt/$project" --zstd -xf -
}

get_destination_path() {
  local dest="$HOME"

  [[ -n $PADAVAN_DEST ]] && dest="$PADAVAN_DEST"

  if is_windows; then
    windows_dest="$(powershell.exe "(New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path")"
    dest="$(wslpath "$windows_dest")"
  fi

  echo -n "$dest"
}

prepare_build_config() {
  log info "Preparing build config"
  config_selection_header=$(printf "%s\n" "${warn_msg} Select your router model ${normal}" \
                                          " Filter by entering text" \
                                          " Select by mouse or arrow keys" \
                                          " Double click or Enter to confirm")

  configs_glob="$mnt/$project/trunk/configs/templates/*/*config"
  configs_glob_slashes=${configs_glob//[^\/]/} # used to tell fzf how much of the path to skip
  config_file="$(find "$mnt/$project" -type f -path "$configs_glob" | \
                fzf +m -e -d / --with-nth ${#configs_glob_slashes}.. \
                --reverse --no-info --bind=esc:ignore --header-first --header "$config_selection_header")"

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

build_firmware() {
  log info "Building firmware"
  _echo " This will take a while, usually 20-60 minutes"
  _echo "$log_follow_reminder"
  ctnr_exec "/opt/$project/trunk" ./build_firmware.sh &>> "$log_file"
  log raw "Done"
}

get_latest_firmware() {
  find "$mnt/$project/trunk/images" -type f -regextype posix-extended -iregex '.*\.(trx|bin)$' -printf "%T@\t%p\n" \
  | sort -V | tail -1 | cut -f2
}

copy_artifacts() {
  _echo " Copying to $1"

  mkdir -p "$1"
  cp -v "$(get_latest_firmware)" "$1"
  cp -v "$mnt/$project/trunk/.config" "$1/${CONFIG_FIRMWARE_PRODUCT_ID}_$(date '+%Y.%m.%d_%H.%M.%S').config"
}

check_firmware_size() {
  partitions="$mnt/$project/trunk/configs/boards/$CONFIG_VENDOR/$CONFIG_FIRMWARE_PRODUCT_ID/partitions.config"
  max_fw_size="$(awk '/Firmware/ { getline; getline; sub(",", ""); print strtonum($2); }' "$partitions")"
  fw_size="$(stat -c %s "$(get_latest_firmware)")"

  if ((fw_size > max_fw_size)); then
    fw_size_fmtd="$(numfmt --grouping "$fw_size") bytes"
    max_fw_size_fmtd="$(numfmt --grouping "$max_fw_size") bytes"
    log err "Firmware size ($fw_size_fmtd) exceeds max size ($max_fw_size_fmtd) for your target device"
  fi
}


handle_exit() {
  if [[ $? != 0 ]]; then
    _echo "\n${err_msg} Error occured, please check log: ${normal}${bold} $log_file"
    _echo " Failed command: $BASH_COMMAND"
  fi

  set +euo pipefail

  log warn "Cleaning"
  podman container exists "$container" && podman rm -f "$container" &>> "$log_file"

  if grep -qsE "^\S+ $(realpath "$mnt") " /proc/mounts; then
    log raw "Unmounting compressed virtual disk"
    $sudo umount "$mnt" &>> "$log_file" || :
  fi

  if [[ -f $disk_img ]]; then
    if decide_delete_disk_img; then
      log raw "Deleting virtual disk image"
      rm -rf "$disk_img" &>> "$log_file"
    else
      log raw "Keeping virtual disk image"
    fi
  fi

  # restore mtu
  if (( ${wan_mtu:-0} > 1280 )); then
    log raw "Setting back network MTU"
    $sudo ip link set "$wan" mtu "$wan_mtu"
  fi
}

main() {
  (( $(id -u) > 0 )) && sudo="sudo" || sudo=""

  # shellcheck disable=SC1090
  [[ -f $PADAVAN_BUILDER_CONFIG ]] && . "$PADAVAN_BUILDER_CONFIG"
  log_follow_reminder=" You can follow the log live in another terminal with ${accent} tail -f '$log_file' "

  prepare

  if [[ $PADAVAN_BUILD_CONTAINER == true ]] \
  || [[ $PADAVAN_BUILD_ALL_LOCALLY == true ]]; then
    log info "Building container image"
    build_container &>> "$log_file"
  fi

  start_container

  if [[ -d $mnt/$project ]]; then
    log warn "Existing source code directory found"

    if decide_reset_and_update_sources; then
      log info "Updating"
      reset_and_update_sources &>> "$log_file"
      get_prebuilt_toolchain &>> "$log_file"
    elif decide_reuse_compiled; then
      log info "Cleaning only neccessary files"
      ctnr_exec "/opt/$project/trunk" make -C user/httpd clean &>> "$log_file"
      ctnr_exec "/opt/$project/trunk" make -C user/rc clean &>> "$log_file"
      ctnr_exec "/opt/$project/trunk" make -C user/shared clean &>> "$log_file"
    else
      log info "Cleaning"
      ctnr_exec "/opt/$project/trunk" ./clear_tree.sh &>> "$log_file"
    fi
  else
    log info "Downloading sources and toolchain"
    ctnr_exec "" git clone --depth 1 -b "$PADAVAN_BRANCH" "$PADAVAN_REPO" &>> "$log_file"

  if [[ $PADAVAN_BUILD_TOOLCHAIN == true ]] \
  || [[ $PADAVAN_BUILD_ALL_LOCALLY == true ]]; then
      build_toolchain
    else
      get_prebuilt_toolchain &>> "$log_file"
    fi
  fi

  # use predefined config
  if [[ -n $PADAVAN_CONFIG ]]; then
    cp "$PADAVAN_CONFIG" "$mnt/$project/trunk/.config"
  else
    prepare_build_config
  fi

  # get variables from build config
  # shellcheck disable=SC1090
  . <(grep "^CONFIG_" "$mnt/$project/trunk/.config")


  if [[ $PADAVAN_PAUSE_BEFORE_BUILD == true ]]; then
    _echo " Source code is in ${accent} $mnt/$project "
    read -rsp " Press ${warn_msg} Enter ${normal} to start build" < /dev/tty; echo
  fi

  build_firmware
  copy_artifacts "$(get_destination_path)"
  check_firmware_size

  log info "All done"
}


trap handle_exit EXIT
main
