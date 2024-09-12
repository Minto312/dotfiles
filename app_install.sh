#!/bin/bash

basic_apps=(
    "zsh" "xsel"
)
additional_apps=(
    "docker-ce" "docker-ce-cli" "containerd.io" "docker-buildx-plugin" "docker-compose-plugin" 
    "code"
)

all_apps=("${basic_apps[@]}" "${additional_apps[@]}")

function help() {
    echo "Usage: setup.sh [OPTION]"
    echo "Install apps for Ubuntu"
    echo ""
    echo "  -c, --console       Install console apps"
    echo "  -f, --full          Install all apps"
    echo "  -h, --help          Display this help and exit"
}

function add_repo() {
    # code
        apt install wget gpg -y
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
        if [ $? -ne 0 ]; then
            echo "Failed to download the key."
            exit 1
        fi
        install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
        if [ $? -ne 0 ]; then
            echo "Failed to install the key."
            exit 1
        fi
        sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
        rm -f packages.microsoft.gpg
        apt install apt-transport-https -y

    # docker
        apt install ca-certificates curl gnupg -y
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        if [ $? -ne 0 ]; then
            echo "Failed to download the Docker key."
            exit 1
        fi
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null


    apt update
}

function console() {
    # Install basic apps
    for app in "${basic_apps[@]}"; do
        echo "Installing $app"
        apt install $app -y
    done

    # neovim
    mv ./nvim /bin/nvim

    # zsh
    chsh -s $(which zsh)
}

function full() {
    # Install full apps
    add_repo
    for app in "${all_apps[@]}"; do
        echo "Installing $app"
        apt install $app -y
    done
}


function main(){
    if [ "$1" == "" ]; then
        
        echo -e "\n\n**  Need any option  **\n\n"
        help
        exit 1
    fi
    if [ "$(whoami)" != "root" ]; then
        echo "\n\n**  Please run as root  **\n\n"
        exit 1
    fi

    chown _apt /var/lib/update-notifier/package-data-downloads/partial/
    apt update

    case "$1" in
        -c|--console)
            console
            ;;
        -f|--full)
            full
            ;;
        -h|--help)
            help
            ;;
        *)
            echo "\n\n**  Invalid option  **\n\n"
            help
            ;;
    esac
}

main "$@"
