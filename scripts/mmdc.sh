#!/usr/bin/zsh
# usage: mmdc.sh <filename.mmd>

if [ -z "$1" ]; then
    echo "Usage: mmdc.sh <filename.mmd>"
    exit 1
fi

docker run --rm -u `id -u`:`id -g` -v $PWD:/data minlag/mermaid-cli -i $1 -o $1.png
