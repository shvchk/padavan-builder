#! /usr/bin/env bash

set -euo pipefail

dest_dir="$HOME"
win_dest_dir="/mnt/c/Users/Public/Downloads"

repo_url="${1:-https://gitlab.com/hadzhioglu/padavan-ng}"
branch="${2:-master}"

dockerfile_url="${repo_url}/raw/${branch}/Dockerfile"
build_script_url="https://github.com/shvchk/padavan-builder/raw/main/container.sh"

dockerfile="$(wget -qO- "$dockerfile_url")"
dockerfile+=$'\nRUN wget -qO /opt/container.sh "'$build_script_url'"'

sudo apt update
sudo apt install podman -y

podman build    --ulimit nofile=9000 -t padavan - <<< "$dockerfile"
podman run --rm --ulimit nofile=9000 -it -v "$dest_dir":/tmp/trx padavan bash /opt/container.sh < /dev/tty

# if we are in WSL, move trx files to $win_dest_dir
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop && -w $win_dest_dir ]]; then
  mkdir "${win_dest_dir}/padavan" || :
  mv "$dest_dir"/*trx "${win_dest_dir}/padavan"
fi
