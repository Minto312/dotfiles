#!/usr/bin/zsh

ncode=$1
chapter=1

while true; do
    curl -s -o temp.txt https://ncode.syosetu.com/$ncode/$chapter
    # エラーページかどうかを確認
    if grep -q "<title>エラー</title>" temp.txt; then
        rm temp.txt
        break
    fi
    
    sed -E "s|<a href=\"/$ncode/([0-9]+)/\"|<a href=\"./\1.html\"|g" temp.txt > ${chapter}.html

    rm temp.txt
    chapter=$((chapter+1))
    printf "\r%d話をダウンロード中..." "${chapter}"
    sleep 1
done

echo "\n全てのダウンロードが完了しました。"