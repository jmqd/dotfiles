if [[ "$(uname)" == "Darwin" ]]; then
	ZSH_ROOT="/Users/$USER/.oh-my-zsh"
elif [[ "$(expr substr $(uname -s) 1 5)" == "Linux" ]]; then
	ZSH_ROOT="/home/$USER/.oh-my-zsh"
fi

export ZSH=$ZSH_ROOT
export TERM="xterm-256color"

ZSH_THEME="mcqueen"
HIST_STAMPS="yyyy/mm/dd"
export PERSONAL_AWS_BUCKET='mcqueen.jordan'

plugins=(git colored-man-pages colorize command-not-found compleat cp extract
history-substring-search tmux)

source $ZSH/oh-my-zsh.sh

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='mvim'
fi

# ssh -- do I want this? Need to look into it.
# export SSH_KEY_PATH="~/.ssh/rsa_id"

# TODO: Investigate if this is better than `bindkey -v` or equivalent.
# to edit the current command in your $EDITOR
# (which is correctly set to vim, obviously)
autoload -z edit-command-line
zle -N edit-command-line
bindkey "\e" edit-command-line

# The only correct setting.
export EDITOR=vim

# Aliases
alias dirs="dirs -v"
alias g++14="g++ -std=c++14"

# make cd do cd and ls, because that's pretty much always what I do anyway
function cd() {
    new_directory="$*";
    if [ $# -eq 0 ]; then 
        new_directory=${HOME};
    fi;
    builtin cd "${new_directory}" && ls
}

function lb() {
    mkdir -p ~/logbook &&
    log_filename=$(date '+%Y-%m-%dT%H:%M:%S%z') &&
    vim ~/logbook/$log_filename &&
    chmod -w ~/logbook/$log_filename
}

# Permanent tmux `dsk` session. TODO: address nesting warning.
if [ -z "$TMUX" ]
then
    tmux attach -t dsk || tmux new -s dsk;
fi
