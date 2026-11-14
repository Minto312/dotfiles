return {
    "lewis6991/gitsigns.nvim",
    -- 変更されたファイルの一覧と、変更前と変更後を左右に並べた差分を表示する (PR のレビュー用)
    -- 元の sindrets/diffview.nvim は 2024 年から更新がないため、保守されているフォークを使う
    { "dlyongemallo/diffview-plus.nvim",
        version = "*",
        cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggle", "DiffviewFileHistory" },
        keys = {
            { "<leader>gv", "<cmd>DiffviewToggle<cr>", desc = "Diffview (作業中の変更)" },
            -- origin の既定のブランチから分かれた後の変更 (PR の差分)
            { "<leader>gV", "<cmd>DiffviewToggle origin/HEAD...HEAD<cr>", desc = "Diffview (PR の差分)" },
        },
    },
}
