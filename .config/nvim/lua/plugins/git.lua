-- PR のレビュー用に、diffview で PR の差分 (比べる元のブランチから分かれた後の変更) を開く

-- worktree を探す場所。Claude は各リポジトリの .claude/worktrees/ に worktree を作る
local WORKTREE_ROOTS = { "~/workspace", "~/dotfiles" }

-- 比べる元のブランチ。origin の既定のブランチを優先し、なければ main・master を使う
local function base_ref(dir)
    for _, ref in ipairs({ "origin/HEAD", "origin/main", "origin/master", "main", "master" }) do
        vim.fn.system({ "git", "-C", dir, "rev-parse", "--verify", "--quiet", ref })
        if vim.v.shell_error == 0 then
            return ref
        end
    end
end

-- dir のリポジトリ (または worktree) の PR の差分を開く
-- --imply-local: 変更後の側を git から取り出した内容でなく実際のファイルにして、LSP を使えるようにする
local function open_pr_diff(dir)
    local base = base_ref(dir)
    if not base then
        vim.notify("比べる元のブランチ (origin/HEAD、main など) が見つかりません: " .. dir, vim.log.levels.WARN)
        return
    end
    vim.cmd(("DiffviewOpen -C=%s %s...HEAD --imply-local"):format(vim.fn.fnameescape(dir), base))
end

local function read_first_line(path)
    return vim.fn.filereadable(path) == 1 and (vim.fn.readfile(path, "", 1)[1] or "") or ""
end

-- WORKTREE_ROOTS の下の .claude/worktrees/ にある worktree を、最近使ったものから順に返す
local function claude_worktrees()
    local cmd = { "find" }
    vim.list_extend(cmd, vim.tbl_map(vim.fn.expand, WORKTREE_ROOTS))
    vim.list_extend(cmd, {
        "-maxdepth", "9",
        "(", "-name", "node_modules", "-o", "-name", "target", "-o", "-name", ".venv",
        "-o", "(", "-name", ".git", "-type", "d", ")", ")", "-prune",
        "-o", "-path", "*/.claude/worktrees/*", "-name", ".git", "-type", "f", "-print",
    })
    local items = {}
    for _, git_file in ipairs(vim.fn.systemlist(cmd)) do
        local dir = vim.fs.dirname(git_file)
        local git_dir = read_first_line(git_file):match("^gitdir: (.+)$")
        local repo = dir:match("^(.*)/%.claude/worktrees/")
        -- 削除済みの worktree の残り (git_dir がない) は除く
        if git_dir and repo and vim.uv.fs_stat(git_dir) then
            local head = read_first_line(git_dir .. "/HEAD")
            -- 最後にコミットやチェックアウトをした日時 (logs/HEAD の更新日時)
            local stat = vim.uv.fs_stat(git_dir .. "/logs/HEAD") or vim.uv.fs_stat(git_dir .. "/HEAD")
            table.insert(items, {
                dir = dir,
                name = vim.fn.fnamemodify(repo, ":~"):gsub("^~/workspace/", "") .. " / " .. dir:sub(#repo + #"/.claude/worktrees/" + 1),
                branch = head:match("^ref: refs/heads/(.+)$") or head:sub(1, 7),
                time = stat and stat.mtime.sec or 0,
            })
        end
    end
    table.sort(items, function(a, b)
        return a.time > b.time
    end)
    return items
end

-- worktree を選んで、その PR の差分を開く
local function pick_worktree()
    local items = claude_worktrees()
    if #items == 0 then
        vim.notify("worktree が見つかりません", vim.log.levels.WARN)
        return
    end
    vim.ui.select(items, {
        prompt = "PR の差分を開く worktree",
        format_item = function(item)
            return ("%s  [%s]  %s"):format(item.name, item.branch, os.date("%Y-%m-%d %H:%M", item.time))
        end,
    }, function(item)
        if item then
            open_pr_diff(item.dir)
        end
    end)
end

return {
    "lewis6991/gitsigns.nvim",
    -- 変更されたファイルの一覧と、変更前と変更後を左右に並べた差分を表示する (PR のレビュー用)
    -- 元の sindrets/diffview.nvim は 2024 年から更新がないため、保守されているフォークを使う
    { "dlyongemallo/diffview-plus.nvim",
        version = "*",
        cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggle", "DiffviewFileHistory" },
        keys = {
            { "<leader>gv", "<cmd>DiffviewToggle<cr>", desc = "Diffview (作業中の変更)" },
            -- 作業ディレクトリのリポジトリの PR の差分。diffview を開いているときは閉じる
            { "<leader>gV", function()
                if require("diffview.lib").get_current_view() then
                    vim.cmd("DiffviewClose")
                else
                    open_pr_diff(vim.fn.getcwd())
                end
            end, desc = "Diffview (PR の差分)" },
            -- worktree を選んで PR の差分を開く (作業ディレクトリを移さずに済む)
            { "<leader>gW", pick_worktree, desc = "Diffview (worktree を選んで PR の差分)" },
        },
    },
}
