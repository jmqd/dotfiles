# ******************************************************************************
# Create directories
# ******************************************************************************
mkdir -p ~/src
mkdir -p ~/cloud

# ******************************************************************************
# Clone repos
# ******************************************************************************
git clone https://github.com/mcqueenjordan/cloudhome.git ~/src/cloudhome

# ******************************************************************************
# setup cron stuff
# ******************************************************************************
echo "* * * * * ~/src/cloudhome/cloudhome/cloudhome.py" >> /tmp/cronstate
crontab /tmp/cronstate
rm /tmp/cronstate