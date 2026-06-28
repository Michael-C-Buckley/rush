-- Treat Rush scripts as shell scripts for Neovim.
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = "*.rush",
  command = "setfiletype sh",
})
