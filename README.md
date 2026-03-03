# dotfiles

```bash
find ~ -name ".*" -maxdepth 1
```

## install

```bash
# only recommended if your name is "Jordan McQueen" ;)
mkdir -p ~/src
git clone https://github.com/mcqueenjordan/dotfiles.git ~/src/dotfiles
nix develop ~/src/dotfiles -c bash ~/src/dotfiles/bin/install.sh
```

## git hooks

```bash
bash ~/src/dotfiles/bin/setup-git-hooks.sh
```

## nix tooling

```bash
# Enter a dev shell with gitleaks/shellcheck/shfmt and bootstrap deps
# (git/python3/awscli2)
nix develop

# Run credential-pattern lint manually
nix run .#secrets-lint
```
