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

#docker
db() {
    docker build -t "$1":"$2" . ${@:3}
}
dr() {
    docker rm $1
    docker run --user $(id -u):$(id -g) --name $*
}
