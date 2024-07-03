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
