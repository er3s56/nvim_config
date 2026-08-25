# Dotfiles

Shared Neovim and Lazygit configuration.

## Requirements

- Neovim (the source environment uses 0.12-dev)
- Git
- Lazygit
- git-delta
- ripgrep
- fd or fdfind
- curl
- A Nerd Font

## Install

Clone this repository, then link the managed configuration into the XDG
configuration directory:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/lazygit"
ln -s "$HOME/dotfiles/nvim" "${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
ln -s "$HOME/dotfiles/lazygit/config.yml" "${XDG_CONFIG_HOME:-$HOME/.config}/lazygit/config.yml"
```

Move any existing files at those destinations to a backup location before
creating the links. Start Neovim and run `:Lazy sync` after the first clone or
after pulling an updated `lazy-lock.json`.

Do not copy `~/.local/share/nvim`, `~/.local/state/nvim`, or `~/.cache/nvim`;
they contain generated plugins, sessions, swap files, and caches.
