return {
    { "mason-org/mason.nvim",
        opts = {
            ensure_installed = {
                "pyright",
                "ruff",
                "vtsls",
                "gopls",
                "rust-analyzer",
                "marksman",
            },
        },
    },
}
