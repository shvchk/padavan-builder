<p align="right">English | <a href="README.ru.md">Русский</a></p>

## Padavan builder

Automated Padavan firmware builder. Can be run on Debian or Ubuntu, including in Windows subsystem for Linux (WSL).

Usage:

```sh
wget -qO- https://github.com/shvchk/padavan-builder/raw/main/host.sh | bash
```

The script will do the following (manual steps in bold, everything else is automated):

- Create Podman image with all necessary dependencies

- Get Padavan sources

- Build the toolchain

- **Ask you to select your router model**

  Model list can be filtered with text input. Use `↑` `↓` arrows to select your model, press `Enter` to confirm.

- **Open the build config file in a text editor** ([micro](https://micro-editor.github.io))

  Edit config to your liking: uncomment (remove `#` at the beginning of the line) features you need, comment features you don't.  
  Save (`Ctrl + S`) and close (`Ctrl + Q`) the file when finished.  
  Text editor fully supports mouse, clipboard and common editing and navigation methods: `Ctrl + C`, `Ctrl + V`, `Ctrl + X`, `Ctrl + Z`, `Ctrl + F`, etc.

- Build the firmware in a temporary Podman container

- Put the built firmware (`trx` file) in your home directory (Linux) or `C:/Users/Public/Downloads/padavan` (WSL)


### Reuse / rebuild

The script won't delete Podman image with toolchain after building the firmware, so you can reuse it.

To rebuild firmware, run:

```sh
podman run --rm --ulimit nofile=9000 -it -v "$HOME":/tmp/trx padavan bash /opt/container.sh
```

This will start from selecting your router model. Built `trx` will be in your in your Linux home directory. If you use WSL, you can then move `trx` to `C:/Users/Public/Downloads/padavan`:

```sh
mv "$HOME"/*trx /mnt/c/Users/Public/Downloads/padavan
```


### Clean / uninstall

To delete everything, just run:

```sh
podman stop -a; podman system prune -af
```

The only thing left would be the podman package itself, all data will be deleted.


### Use another repository or branch

By default, the script uses [gitlab.com/hadzhioglu/padavan-ng](https://gitlab.com/hadzhioglu/padavan-ng) repository and `master` branch. To use other repository and branch, you can pass it as a parameter to the script: `host.sh <repo_url> <branch>`. When running via pipe, as we did initially, parameters can be passed like this:

```sh
wget -qO- https://github.com/shvchk/padavan-builder/raw/main/host.sh | bash -s -- https://example.com/anonymous/padavan dev
```

In the example above, we use `https://example.com/anonymous/padavan` repo and `dev` branch.

Repository should contain `Dockerfile`.
