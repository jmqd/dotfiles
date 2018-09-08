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

# ******************************************************************************
# Set system-dependent variables
# ******************************************************************************
PYTHON_EXECUTABLE_PATH=`which python3`

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
ln -s ~/cloud/mcqueen.jordan/dotfiles/.aws/credentials ~/.aws/credentials
ln -s ~/cloud/mcqueen.jordan/dotfiles/.env ~/.env
ln -s ~/cloud/mcqueen.jordan/dotfiles/.git-credentials ~/.git-credentials

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
ln -sf ~/src/dotfiles/.zsh_aliases ~/.zsh_aliases
ln -sf ~/src/dotfiles/.zsh_functions ~/.zsh_functions
ln -sf ~/src/dotfiles/.zshrc ~/.zshrc
ln -sf ~/src/dotfiles/.spacemacs ~/.spacemacs
ln -sf ~/src/dotfiles/.gitconfig ~/.gitconfig

# ******************************************************************************
echo "Setting up crontab stuff..."
# ******************************************************************************
echo "* * * * * ~/src/cloudhome/bin/ensure-cloudhome-running.sh ${PYTHON_EXECUTABLE_PATH} &> /tmp/cloudhome.debug" >> /tmp/cronstate
crontab /tmp/cronstate

# ******************************************************************************
echo "Cleaning up..."
# ******************************************************************************
rm /tmp/cronstate
echo "You'll have to restart your shell for things to take effect."
