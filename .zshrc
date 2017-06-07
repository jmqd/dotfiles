# end of ohmyzsh default configs
# THIS_FILE >> ~/.zshrc

function cd() {
    new_directory="$*";
    if [ $# -eq 0 ]; then 
        new_directory=${HOME};
    fi;
    builtin cd "${new_directory}" && ls
}

export EDITOR=/usr/local/bin/vim

alias dirs="dirs -v"

tmux has-session -t dsk
if [ $? != 0 ]
then
  tmux new-session -s dsk
fi
tmux attach -t dsk  
