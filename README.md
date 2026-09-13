# utils
Just some random utility files that I want to be able to publicly access from anywhere and remember their link easily.

| Script | What it does |
| --- | --- |
| `setup.sh` | Brings a fresh Debian/Ubuntu machine up, from apt packages to applying the chezmoi dotfiles. |
| `check.sh` | Reports whether the machine it runs on follows the SSH key convention: one ed25519 key at `~/.ssh/id_ed25519`, declared on GitHub under both the Authentication and the Signing role. Read-only, exits non-zero on a failure. |
| `setup.ps1` | The Windows counterpart of `setup.sh`. |
