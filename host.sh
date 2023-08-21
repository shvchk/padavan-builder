#! /usr/bin/env bash

set -euo pipefail

dest_dir="$HOME"
win_dest_dir="/mnt/c/Users/Public/Downloads"
repo_url="${1:-https://gitlab.com/hadzhioglu/padavan-ng}"
branch="${2:-master}"

# text decoration utilities
normal=$(tput sgr0)
bold=$(tput bold)
info_msg="$(tput setab 33; tput setaf 231)${bold}" # blue bg, white text
warn_msg="$(tput setab 220; tput setaf 16)${bold}" # yellow bg, black text
accent="$(tput setab 238; tput setaf 231)${bold}" # gray bg, white text
_echo() { echo -e "${*}${normal}"; } # unset formatting after outputting

tmp_dir="$(mktemp -d)"
log_file="${tmp_dir}/padavan-builder.log"
log_follow_reminder=" You can follow the log live in another terminal with ${accent} tail -f '$log_file' "
_log() { echo -e "$(date +'%Y.%m.%d %H.%M.%S') - ${*}" &>> "$log_file"; }

echo "$(date +'%Y.%m.%d %H.%M.%S') - Starting" > "$log_file"
_echo "\n${info_msg} Log file: ${normal}${bold} ${log_file}"
_echo "$log_follow_reminder"

handle_exit() {
  if [[ $? != 0 ]]; then
    _echo "\n${warn_msg} Error occured, please check log: ${normal}${bold} ${log_file}"
    _echo " Failed command: $BASH_COMMAND"
  fi

  podman rm -f padavan &>> "$log_file"
}

trap handle_exit EXIT

_echo "\n${info_msg} Installing podman and utilities "
_log  "Installing podman and utilities"
sudo apt update &>> "$log_file"
sudo apt install fzf micro podman -y &>> "$log_file"

_echo "\n${info_msg} Creating a container image and building the toolchain "
_log  "Creating a container image and building the toolchain"
_echo " This will take a while, usually 20-60 minutes"
_echo "$log_follow_reminder"
podman build --ulimit nofile=9000 --squash -t padavan "${repo_url}/raw/${branch}/Dockerfile" &>> "$log_file"
_echo " Done"
_log  " Done"

_echo "\n${info_msg} Starting container to build firmware "
_log  "Starting container to build firmware"
podman run --ulimit nofile=9000 -dt -v "$dest_dir":/tmp/trx -w /opt/padavan-ng/trunk --name padavan padavan &>> "$log_file"

config_selection_header=$(printf "%s\n" "${warn_msg} Select your router model ${normal}" \
                                        " Filter by entering text" \
                                        " Select by mouse or arrow keys" \
                                        " Double click or Enter to confirm")

config_file="$(podman exec padavan sh -c "find configs/templates/*/*config" | \
               fzf +m -e -d / --with-nth 3.. --reverse --no-info --bind=esc:ignore --header-first --header "$config_selection_header")"

podman cp padavan:"$config_file" "${tmp_dir}/padavan-build.config"

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

micro -autosave 1 -ignorecase 1 -keymenu 1 -scrollbar 1 -filetype shell "${tmp_dir}/padavan-build.config"
podman cp "${tmp_dir}/padavan-build.config" padavan:.config

_echo " Build config backup: ${tmp_dir}/padavan-build.config"

_echo "\n${info_msg} Building firmware "
_log  "Building firmware"
_echo " This will take a while, usually 10-30 minutes"
_echo "$log_follow_reminder"
podman exec padavan ./clear_tree.sh &>> "$log_file"
podman exec padavan ./build_firmware.sh &>> "$log_file"
_echo " Done"
_log  " Done"

_echo " Copying firmware to $dest_dir"
podman exec padavan sh -c "cp images/*trx /tmp/trx"

# if we are in WSL, move trx files to $win_dest_dir
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop && -w $win_dest_dir ]]; then
  _echo " Moving firmware to ${win_dest_dir}/padavan"
  mkdir "${win_dest_dir}/padavan" &> /dev/null || :
  mv "$dest_dir"/*trx "${win_dest_dir}/padavan"
fi

_echo "\n${info_msg} All done "
_log  " All done"
