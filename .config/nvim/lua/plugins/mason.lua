return {
    {
        "williamboman/mason.nvim",
        opts = {
            ensure_installed = {
            "stylua",
            "shellcheck",
            "shfmt",
            "flake8",
            "pyright"
            },
        },
    },
    "williamboman/mason-lspconfig.nvim",
    "neovim/nvim-lspconfig",
}
