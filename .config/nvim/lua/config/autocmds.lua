-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

-- " ターミナルを開いたらに常にinsertモードに入る
vim.api.nvim_create_autocmd({ 'TermOpen' }, {
    pattern = '*',
    command = 'startinsert',
})
-- " ターミナルモードで行番号を非表示
-- autocmd TermOpen * setlocal norelativenumber
-- autocmd TermOpen * setlocal nonumber

local function close_volatile_terminal(bufnr)
    vim.api.nvim_buf_delete(bufnr, {force = true})
  end
  
  local function open_volatile_terminal(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    opts = vim.tbl_extend('force', opts or {}, {
      on_exit = function(job_id, code, event)
        close_volatile_terminal(bufnr)
      end
    })
  
    -- 終了時にバッファを消すterminalを開く
    vim.fn.termopen(vim.o.shell, opts)
  end
  
  local function nosplit_volatile_terminal(opts)
    -- 初期バッファの場合は新しいバッファを開く
    if vim.bo.buftype == "" and vim.fn.line2byte(vim.fn.line('$')) == -1 then
      vim.cmd("enew")
    end
    open_volatile_terminal(opts)
  end
  
  local function split_volatile_terminal(size, mods, opts)
    -- 指定方向に画面分割
    vim.cmd(mods .. ' new')
    open_volatile_terminal(opts)
  
    -- 指定方向にresize
    size = size or vim.v.count
    if size == 0 then
      size = size or 10 -- デフォルトサイズを設定（ここで10は例です）
    end
    if size ~= 0 then
      vim.cmd(mods .. ' resize ' .. size)
    end
  end
  
  -- コマンドを定義
  vim.api.nvim_create_user_command('OpenVolatileTerminal', function()
    nosplit_volatile_terminal({})
  end, {})
  
  vim.api.nvim_create_user_command('NewVolatileTerminal', function(params)
    split_volatile_terminal(params.count, params.mods or '', {})
  end, { count = true })
  
  vim.api.nvim_create_user_command('OpenVolatileTerminalFromCurrentBuffer', function()
    nosplit_volatile_terminal({cwd = vim.fn.expand('%:p:h')})
  end, {})
  
  vim.api.nvim_create_user_command('NewVolatileTerminalFromCurrentBuffer', function(params)
    split_volatile_terminal(params.count, params.mods or '', {cwd = vim.fn.expand('%:p:h')})
  end, { count = true })
  

-- 水平分割でターミナルを開く関数（ウィンドウのサイズを適切に調整）
local function split_horizontal_volatile_terminal(size, opts)
    -- 現在のウィンドウを保持
    local current_win = vim.api.nvim_get_current_win()
  
    -- 指定サイズで水平分割
    vim.cmd('split')
    open_volatile_terminal(opts)
  
    -- 指定されたサイズにターミナルウィンドウをリサイズ
    size = size or vim.v.count
    if size == 0 then
      size = 10 -- デフォルトサイズ（必要に応じて変更可能）
    end
    if size ~= 0 then
      vim.cmd('resize ' .. size)
    end
  
    -- 元のウィンドウに戻る（ターミナルウィンドウでなく、元のソースコード部分にフォーカスを戻す）
    vim.api.nvim_set_current_win(current_win)
  end
  
  -- ターミナル終了時にバッファを閉じる
  local function open_volatile_terminal(opts)
    local bufnr = vim.api.nvim_get_current_buf()
  
    opts = vim.tbl_extend('force', opts or {}, {
      on_exit = function()
        -- ターミナルが終了したら、そのバッファを削除
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    })
  
    -- ターミナルを開く
    vim.fn.termopen(vim.o.shell, opts)
  end
  
  -- コマンドを定義
  vim.api.nvim_create_user_command('HorizontalVolatileTerminal', function(params)
    split_horizontal_volatile_terminal(params.count, {})
  end, { count = true })
  
  vim.api.nvim_create_user_command('HorizontalVolatileTerminalFromCurrentBuffer', function(params)
    split_horizontal_volatile_terminal(params.count, {cwd = vim.fn.expand('%:p:h')})
  end, { count = true })
  

vim.api.nvim_create_autocmd("InsertLeave", {
    pattern = "*",
    command = "write",
})

