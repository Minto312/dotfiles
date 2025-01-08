#utils
alias ls='ls -lha --color=auto'
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



mp4-comp() {
    ffmpeg -i $1 -c:v hevc_nvenc -b:v 2500k -preset slow -pass 1 -an -passlogfile mylogfile -f null /dev/null

    ffmpeg -i $1 -c:v hevc_nvenc -b:v 2500k -r 24 -crf 24 -preset slow -pass 2 -c:a aac -b:a 128k -passlogfile mylogfile cmp_$1
    rm mylogfile-0.log
}
