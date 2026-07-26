return {
    "nvim-treesitter/nvim-treesitter",
    "akinsho/bufferline.nvim",
    "nvim-lualine/lualine.nvim",
    "petertriho/nvim-scrollbar",
    "folke/noice.nvim",
    { "kevinhwang91/nvim-ufo", dependencies = { "kevinhwang91/promise-async" } },
    { "snacks.nvim", opts = {
        scroll = { enabled = false },
        picker = {
            sources = {
                -- 起動時の snacks.explorer で gitignore 済みファイルも表示する
                -- (dotfile も出したい場合は hidden = true も追加)
                explorer = { ignored = true },
            },
        },
    } },
}
