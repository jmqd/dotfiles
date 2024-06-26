# ******************************************************************************
# Pre-requisites
# ******************************************************************************
cat <<"EOF"
Pre-requisites
---

python3
git
aws (w/ credentials configured)
EOF

sleep 2

# ******************************************************************************
echo "Installing emacs configuration base"
# ******************************************************************************
git clone --depth 1 https://github.com/hlissner/doom-emacs ~/.emacs.d
~/.emacs.d/bin/doom install

# ******************************************************************************
echo "Creating common directories in ~/ ..."
# ******************************************************************************
mkdir -p ~/src
mkdir -p ~/cloud
mkdir -p ~/cloud/mcqueen.jordan
mkdir -p ~/.aws

# ******************************************************************************
echo "Copying data from your cloud storage..."
# ******************************************************************************
aws s3 sync s3://mcqueen.jordan ~/cloud/mcqueen.jordan/

# ******************************************************************************
echo "Symbolically linking dotfiles not in source control..."
# TODO: Make this recursively ln -s all of them. It's a tad bit tricky...
# ******************************************************************************
ln -sf ~/cloud/mcqueen.jordan/secrets/dotfiles/.password-store ~/.password-store
ln -sf ~/cloud/mcqueen.jordan/secrets/dotfiles/.gpg-id ~/.gpg-id

# We don't want to override something important. No force flag.
ln -s ~/cloud/mcqueen.jordan/dotfiles/.env ~/.env
ln -s ~/cloud/mcqueen.jordan/secrets/dotfiles/.git-credentials ~/.git-credentials
ln -s ~/cloud/mcqueen.jordan/dotfiles/.cloudhome.json ~/.cloudhome.json

# ******************************************************************************
echo "Sourcing environment variables..."
# ******************************************************************************
. ~/.env

# ******************************************************************************
echo "Cloning & pulling latest for git repos..."
# ******************************************************************************
git clone https://github.com/mcqueenjordan/cloudhome.git ~/src/cloudhome
git clone https://github.com/mcqueenjordan/dotfiles.git ~/src/dotfiles

git -C ~/src/cloudhome pull --rebase
git -C ~/src/dotfiles pull --rebase

# ******************************************************************************
echo "Symbolically link custom dotfiles to ~/src/dotfiles/."
# ******************************************************************************
ln -sf ~/src/dotfiles/.gitconfig ~/.gitconfig
ln -sf ~/src/dotfiles/.gitmessage ~/.gitmessage
ln -sf ~/src/dotfiles/.Xmodmap ~/.Xmodmap
ln -sf ~/src/dotfiles/.doom.d/config.el ~/.doom.d/config.el
ln -sf ~/src/dotfiles/.doom.d/init.el ~/.doom.d/init.el
ln -sf ~/src/dotfiles/.doom.d/packages.el ~/.doom.d/packages.el
ln -sf ~/src/dotfiles/.sqliterc ~/.sqliterc
ln -sf ~/src/dotfiles/.gdbinit ~/.gdbinit
ln -sf ~/src/dotfiles/.wezterm.lua ~/.wezterm.lua
sudo ln -sf ~/src/dotfiles/nixos/configuration.nix /etc/nixos/configuration.nix

mkdir -p ~/.i3
ln -sf ~/src/dotfiles/.i3/config ~/.i3/config
ln -sf ~/src/dotfiles/.i3/status_bar.toml ~/.i3/status_bar.toml

echo "You'll have to restart your shell for things to take effect."
