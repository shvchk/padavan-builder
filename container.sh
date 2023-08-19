#! /usr/bin/env bash

set -euo pipefail

apt install fzf micro -y

cd /opt/padavan-ng/trunk
cp "$(find configs/templates/*/*config | fzf -e)" .config
micro .config

./clear_tree.sh
./build_firmware.sh

cp images/*trx /tmp/trx
