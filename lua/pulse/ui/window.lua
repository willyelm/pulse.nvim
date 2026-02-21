local M = {}

function M.configure_content_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldenable = false
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldexpr = "0"
  vim.wo[win].foldtext = ""
  vim.wo[win].statuscolumn = ""
  vim.wo[win].conceallevel = 0
  vim.wo[win].concealcursor = ""
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].wrap = false
end

return M
