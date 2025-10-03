#!/usr/bin/zsh
# usage: mmdc.sh <mmd text>

if [ -z "$1" ]; then
    echo "Usage: mmdc.sh <mmd text>"
    exit 1
fi

filename=temp

echo "$1" > $filename.mmd

if [ -n "$2" ]; then
    docker run --rm -u `id -u`:`id -g` -v $PWD:/data minlag/mermaid-cli -i $filename.mmd -o $filename.$2
fi

docker run --rm -u `id -u`:`id -g` -v $PWD:/data minlag/mermaid-cli -i $filename.mmd -o $filename.png
