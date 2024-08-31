alias ls='ls -lha'

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
    docker build -t "$1":"$2" .
}
dr() {
    docker rm $1
    docker run --name $*
}
