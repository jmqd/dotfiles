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

# give myself a chance to ctrl-c if I realize I'm missing a dependency
sleep 3s

# ******************************************************************************
# Set system-dependent variables
# ******************************************************************************
PYTHON_EXECUTABLE_PATH=`which python3`

# ******************************************************************************
# Create directories
# ******************************************************************************
echo "Creating common directories in ~/ ..."
mkdir -p ~/src
mkdir -p ~/cloud
mkdir -p ~/cloud/mcqueen.jordan
mkdir -p ~/.aws

# ******************************************************************************
# Copy cloud data
# ******************************************************************************
echo "Copying data from your cloud bucket..."
aws s3 sync s3://mcqueen.jordan ~/cloud/mcqueen.jordan/

# ******************************************************************************
# Symbolically link dotfiles not in source control
# TODO: Make this recursively ln -s all of them. It's a tad bit tricky...
# ******************************************************************************
echo "Symbolically linking dotfiles not in source control..."
ln -s ~/cloud/mcqueen.jordan/dotfiles/.aws/credentials ~/.aws/credentials
ln -s ~/cloud/mcqueen.jordan/dotfiles/.env ~/.env

# ******************************************************************************
# Source non-public environment variables
# ******************************************************************************
echo "Sourcing environment variables..."
. ~/.env

# ******************************************************************************
# Clone repos
# ******************************************************************************
echo "Cloning git repos..."
git clone https://github.com/mcqueenjordan/cloudhome.git ~/src/cloudhome
git clone https://github.com/mcqueenjordan/dotfiles.git ~/src/dotfiles
git clone https://github.com/mcqueenjordan/learning.git ~/src/learning

echo "Ensuring repos are up-to-date..."
git -C ~/src/cloudhome pull --rebase
git -C ~/src/dotfiles pull --rebase
git -C ~/src/learning pull --rebase

# ******************************************************************************
echo "Symbolically link custom dotfiles to ~/src/dotfiles/."
# ******************************************************************************
ln -sf ~/src/dotfiles/.zsh_aliases ~/.zsh_aliases
ln -sf ~/src/dotfiles/.zsh_functions ~/.zsh_functions
ln -sf ~/src/dotfiles/.zshrc ~/.zshrc

# ******************************************************************************
# setup cron stuff
# ******************************************************************************
echo "Setting up crontab stuff..."
echo "* * * * * ~/src/cloudhome/bin/ensure-cloudhome-running.sh ${PYTHON_EXECUTABLE_PATH} &> /tmp/cloudhome.debug" >> /tmp/cronstate
crontab /tmp/cronstate
rm /tmp/cronstate
