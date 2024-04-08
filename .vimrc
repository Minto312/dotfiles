"一般的な設定

"文字コードをUTF-8に設定
set fenc=utf-8
"バックアップファイルを作らない
set nobackup
"スワップファイルを作らない
set noswapfile
"編集中のファイルが変更されたら自動で読み直す
set autoread
"バッファが編集中でもそのほかのファイルを開けるようにする
set hidden
"入力中のコマンドをステータスに表示する
set showcmd
"オートインデント
set autoindent
"音を鳴らさない
set noerrorbells


"Tab関係

"Tabを半角スペースにする
set expandtab
set tabstop=4
set shiftwidth=4



"見た目の調整

"行番号を表示
set number
"現在の行を強調表示
"set cursorline
"括弧入力時に対応する括弧を表示
set showmatch
"ステータスラインを常に表示
set laststatus=2
"シンタックスハイライトの有効化
syntax enable
"タイトルを表示
set title
"カラーテーマ
colorscheme desert
"タブと行末のスペースはハイライトしておく
set list
set listchars=tab:\ \ ,trail:\ 
highlight SpecialKey ctermbg=235 guibg=#2c2d27
"一行は80文字程度に収める
set colorcolumn=80
"80列目の色は灰色周辺の色に変更
highlight ColorColumn ctermbg=235 guibg=#2c2d27


"検索系

"検索文字列が小文字の場合は大文字小文字を区別しない
set ignorecase
"検索文字列に大文字が含まれている場合は区別する
set smartcase
"検索時に最後まで行ったら最初に戻る
set wrapscan
"検索語をハイライトで表示
set hlsearch
"入力したそばから検索を行う
set incsearch


"netrw関連

"ディレクトリ構造をtree形式で表示する
let g:netrw_liststyle = 3
"バナーを消す
let g:netrw_banner = 0
"新規ファイルを横に開く
let g:netrw_browse_split = 2
