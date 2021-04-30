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

sudo emerge net-mail/mu www-client/w3m sys-fs/inotify-tools dev-perl/AnyEvent \
            dev-perl/AnyEvent-I3 app-editors/vim app-editors/emacs \
            media-video/vlc

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

# ******************************************************************************
echo "Sourcing environment variables..."
# ******************************************************************************
. ~/.env

# ******************************************************************************
echo "Cloning & pulling latest for git repos..."
# ******************************************************************************
git clone https://github.com/mcqueenjordan/cloudhome.git ~/src/cloudhome
git clone https://github.com/mcqueenjordan/dotfiles.git ~/src/dotfiles
git clone https://github.com/mcqueenjordan/learning.git ~/src/learning

git -C ~/src/cloudhome pull --rebase
git -C ~/src/dotfiles pull --rebase
git -C ~/src/learning pull --rebase

# ******************************************************************************
echo "Symbolically link custom dotfiles to ~/src/dotfiles/."
# ******************************************************************************
ln -sf ~/src/dotfiles/.gitconfig ~/.gitconfig
ln -sf ~/src/dotfiles/.gitmessage ~/.gitmessage
ln -sf ~/src/dotfiles/.Xmodmap ~/.Xmodmap

# ******************************************************************************
echo "rsyncing /etc"
# ******************************************************************************
rsync -r ~/src/dotfiles/etc/ /etc/

echo "You'll have to restart your shell for things to take effect."
