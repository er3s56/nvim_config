# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Tests

Every file in `tests/` is a test: a script that exits 0 when it passes, run as
`nvim -u init.lua -l tests/<name>.lua` from this directory. The runner does that
for all of them and sums up:

```sh
nvim -l tests/run.lua              # everything
nvim -l tests/run.lua git_panel    # by name
nvim -l tests/run.lua -j 4         # four at a time
nvim -l tests/run.lua --list
```

Failures that are known to come from outside this configuration are listed in
`tests/run.lua` and reported apart.
