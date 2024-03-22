ZSH_THEME="mcqueen"

plugins=(
  git
)

source $ZSH/oh-my-zsh.sh
export TERM='xterm-256color'
export EDITOR='emacs'
HIST_STAMPS='yyyy-mm-dd'

# Allows me to press escape to edit the command line in $EDITOR.
autoload -z edit-command-line
zle -N edit-command-line
bindkey "\e" edit-command-line

TMOUT=1
TRAPALRM() {
    zle reset-prompt
}

. ~/.env
