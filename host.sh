#! /usr/bin/env bash

set -euo pipefail

dest_dir="$HOME"
win_dest_dir="/mnt/c/Users/Public/Downloads"
dockerfile="https://gitlab.com/hadzhioglu/padavan-ng/raw/master/Dockerfile"
build_script=""

sudo apt update
sudo apt install podman -y

wget -qO- "$dockerfile"   | podman build    --ulimit nofile=9000 -t padavan -
wget -qO- "$build_script" | podman run --rm --ulimit nofile=9000 -i -v "$dest_dir":/tmp/trx padavan

# if we are in WSL, move trx files to $win_dest_dir
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop && -w $win_dest_dir ]]; then
  mkdir "${win_dest_dir}/padavan"
  mv "$dest_dir"/*trx "${win_dest_dir}/padavan"
fi
