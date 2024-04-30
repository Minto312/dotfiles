-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
-- 一般的な設定

-- 文字コードをUTF-8に設定
vim.opt.fenc = "utf-8"
-- バックアップファイルを作らない
--vim.opt.nobackup = true
-- スワップファイルを作らない
--vim.opt.noswapfile = true
-- 編集中のファイルが変更されたら自動で読み直す
vim.opt.autoread = true
-- バッファが編集中でもそのほかのファイルを開けるようにする
vim.opt.hidden = true
-- 入力中のコマンドをステータスに表示する
vim.opt.showcmd = true
-- オートインデント
vim.opt.autoindent = true
-- 音を鳴らさない
--vim.opt.noerrorbells = true


-- Tab関係

-- Tabを半角スペースにする
vim.opt.expandtab = true
vim.opt.tabstop=4
vim.opt.shiftwidth=4



-- 見た目の調整

-- 行番号を表示
vim.opt.number = true
-- 現在の行を強調表示
-- vim.opt.cursorline = true
-- 括弧入力時に対応する括弧を表示
vim.opt.showmatch = true
-- ステータスラインを常に表示
vim.opt.laststatus=2
-- シンタックスハイライトの有効化
--syntax enable = true
-- タイトルを表示
vim.opt.title = true
-- カラーテーマ
--colorscheme desert
-- タブと行末のスペースはハイライトしておく
--vim.opt.list
--vim.opt.listchars=tab:\ \ ,trail:\ 
--highlight SpecialKey ctermbg=235 guibg=#2c2d27
-- 一行は80文字程度に収める
--vim.opt.colorcolumn = "80"
-- 80列目の色は灰色周辺の色に変更
--highlight ColorColumn ctermbg=235 guibg=#2c2d27


-- 検索系

-- 検索文字列が小文字の場合は大文字小文字を区別しない
vim.opt.ignorecase = true
-- 検索文字列に大文字が含まれている場合は区別する
vim.opt.smartcase = true
-- 検索時に最後まで行ったら最初に戻る
vim.opt.wrapscan = true
-- 検索語をハイライトで表示
vim.opt.hlsearch = true
-- 入力したそばから検索を行う
vim.opt.incsearch = true


-- netrw関連

-- ディレクトリ構造をtree形式で表示する
--let g:netrw_liststyle = 3
-- バナーを消す
--let g:netrw_banner = 0
-- 新規ファイルを横に開く
--let g:netrw_browse_split = 2

--[[
let $CACHE = expand('~/.cache')
if !($CACHE->isdirectory())
  call mkdir($CACHE, 'p')
endif
if &runtimepath !~# '/dein.vim'
  let s:dir = 'dein.vim'->fnamemodify(':p')
  if !(s:dir->isdirectory())
    let s:dir = $CACHE .. '/dein/repos/github.com/Shougo/dein.vim'
    if !(s:dir->isdirectory())
      execute '!git clone https://github.com/Shougo/dein.vim' s:dir
    endif
  endif
  execute 'vim.opt.runtimepath^='
        \ .. s:dir->fnamemodify(':p')->substitute('[/\\]$', '', '')
endif
]]
