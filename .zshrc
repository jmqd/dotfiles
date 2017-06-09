# end of ohmyzsh default configs
# THIS_FILE >> ~/.zshrc

# TODO: Investigate if this is better than `bindkey -v` or equivalent.
# to edit the current command in your $EDITOR
# (which is correctly set to vim, obviously)
autoload -z edit-command-line
zle -N edit-command-line
bindkey "\e" edit-command-line

# make cd do cd and ls, because that's pretty much always what I do anyway
function cd() {
    new_directory="$*";
    if [ $# -eq 0 ]; then 
        new_directory=${HOME};
    fi;
    builtin cd "${new_directory}" && ls
}

# The only correct setting.
export EDITOR=/usr/local/bin/vim

# Aliases
alias dirs="dirs -v"
alias g++14="g++ -std=c++14"

# Permanent tmux `dsk` session. TODO: address nesting warning.
tmux has-session -t dsk
if [ $? != 0 ]
then
  tmux new-session -s dsk
fi
tmux attach -t dsk  
