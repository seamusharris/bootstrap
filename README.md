# bootstrap

One-shot setup for a fresh Linux server. Installs base packages, modern
Neovim, shell tooling, then clones my private dotfiles repo via
[chezmoi](https://www.chezmoi.io/) using **SSH agent forwarding**.

## Usage

On your laptop, connect with agent forwarding so the script can clone the
private dotfiles repo using your local SSH key:

```sh
ssh -A user@new-server
```

Or set it permanently in `~/.ssh/config`:

```
Host *
  ForwardAgent yes
```

On the server:

```sh
curl -fsSL https://raw.githubusercontent.com/seamusharris/bootstrap/main/bootstrap-linux.sh -o ~/bootstrap-linux.sh
chmod +x ~/bootstrap-linux.sh
~/bootstrap-linux.sh
exec zsh
nvim
```

The script verifies your forwarded SSH key is authorized on GitHub before
installing anything, so it fails fast if agent forwarding isn't working.

## What it does

1. **Pre-flight**: confirms `ssh-add -l` returns keys.
2. **dnf**: installs zsh, tmux, git, fzf, bat, fd, nodejs, npm, python3-pip, …
3. **Python**: if the default `python3` is older than 3.10 (Mason needs ≥3.10
   for `black`), installs the newest available `python3.X` (tries 3.13, 3.12,
   3.11, 3.10).
4. **Neovim**: installs the official AppImage extracted to `/opt/nvim`,
   symlinked at `/usr/local/bin/nvim` (Rocky's dnf nvim is too old for modern
   plugins). Skipped if existing nvim is already ≥0.11.
5. **Tools**: starship, zoxide, eza.
6. **chezmoi**: installs and runs `chezmoi init --apply --ssh seamusharris`,
   pulling the private dotfiles repo via your forwarded SSH key.
7. **Shell**: changes default shell to zsh.

## Targets

- Rocky Linux 9+ (primary)
- Should work on any RHEL-family distro with dnf

If you run it elsewhere and it breaks, open an issue or PR.

## TODO when migrating to Rocky 10+ / newer glibc

- **Re-enable `nvim-treesitter` on Linux**: it's currently gated off via a
  chezmoi conditional in the dotfiles repo (`init.lua.tmpl`). The blocker is
  that the upstream `tree-sitter` CLI prebuilt binary requires glibc ≥2.39
  (Rocky 9 ships 2.34). On Rocky 10+ the prebuilt should just work — install
  it (e.g. `npm install -g tree-sitter-cli` or download from the
  tree-sitter releases page), then drop the `{{ if ne .chezmoi.os "linux" }}`
  wrapper around the nvim-treesitter plugin spec.
- **Reconsider `gcc`/`make` in this script**: they were added so the legacy
  nvim-treesitter compile path could work. With treesitter disabled on
  Linux, neither is currently used for anything. They can be removed if you
  want a leaner server, or kept for general-purpose admin work. When
  treesitter is re-enabled with the CLI, they're no longer needed.
