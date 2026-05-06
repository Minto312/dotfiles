return {
    {"nvim-neo-tree/neo-tree.nvim",
    keys = {
        -- サイドバー
        { "<leader>e", function()
            require("neo-tree.command").execute({ toggle = true, dir = LazyVim.root(), position = "left" })
        end, desc = "Explorer NeoTree (Root Dir)" },
        { "<leader>E", function()
            require("neo-tree.command").execute({ toggle = true, dir = vim.uv.cwd(), position = "left" })
        end, desc = "Explorer NeoTree (cwd)" },
        -- float (f prefix)
        { "<leader>fe", function()
            require("neo-tree.command").execute({ toggle = true, dir = LazyVim.root(), position = "float" })
        end, desc = "Explorer NeoTree (Root Dir) Float" },
        { "<leader>fE", function()
            require("neo-tree.command").execute({ toggle = true, dir = vim.uv.cwd(), position = "float" })
        end, desc = "Explorer NeoTree (cwd) Float" },
        { "<leader>be", function()
            require("neo-tree.command").execute({ source = "buffers", toggle = true, position = "float" })
        end, desc = "Buffer Explorer Float" },
        { "<leader>ge", function()
            require("neo-tree.command").execute({ source = "git_status", toggle = true, position = "float" })
        end, desc = "Git Explorer Float" },
    },
    opts = {
        filesystem = {
            filtered_items = {
                visible = true,
                show_hidden_count = true,
                hide_dotfiles = false,
                hide_gitignored = false,
                hide_by_name = {},
                never_show = {},
            },
        }
    }},
    "kyazdani42/nvim-web-devicons",
}
