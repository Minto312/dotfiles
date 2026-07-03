return {
    -- Markdown レンダリング (テーブル罫線・見出し・コードブロック等)
    { "MeanderingProgrammer/render-markdown.nvim",
        ft = { "markdown" },
        opts = {
            render_modes = { "n", "c" },
            anti_conceal = { enabled = false },
            code = {
                sign = false,
                width = "block",
                right_pad = 1,
            },
            heading = {
                sign = false,
                icons = {},
            },
        },
        config = function(_, opts)
            require("render-markdown").setup(opts)
            Snacks.toggle({
                name = "Render Markdown",
                get = require("render-markdown").get,
                set = require("render-markdown").set,
            }):map("<leader>um")
        end,
    },
    -- Markdown LSP (リンク・参照・目次)
    { "neovim/nvim-lspconfig",
        opts = {
            servers = {
                marksman = {},
            },
        },
    },
}
