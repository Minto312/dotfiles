#utils
alias ls='ls -lha'
alias clip='xsel --clipboard --input'
alias pwdc='pwd | clip'

#git
alias gs='git status'
alias ga='git add'
gc() {
    combined_args=""
    for arg in "$@"; do
        combined_args="$combined_args $arg"
    done

    git commit -m "$combined_args"
}

alias gbs='git switch'
alias gbc='git switch -c'


#docker
db() {
    docker build -t "$1":"$2" . ${@:3}
}
dr() {
    docker rm $1
    docker run --name $*
}

dremap() {
    if [ $# -ne 3 ]; then
      echo "引数は右記のように指定してください：container name, host port, container port"
      exit 1
    fi
    binds=$(docker inspect --format '{{ .HostConfig.Binds }}' omakase-front)
    bind=$binds[2,-2]

    docker stop "$1"
    docker commit "$1" tmp:rerun 
    dr "$1" -tv $bind -p ${@:2} tmp:rerun bash
}

