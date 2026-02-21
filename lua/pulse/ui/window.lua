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

function M.configure_isolated_buffer(buf, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  opts = opts or {}
  vim.bo[buf].buftype = opts.buftype or "nofile"
  vim.bo[buf].bufhidden = opts.bufhidden or "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = opts.modifiable == true
  vim.bo[buf].filetype = opts.filetype or ""
  for _, key in ipairs({ "gitsigns_disable", "miniindentscope_disable", "minianimate_disable", "illuminate_disable" }) do
    vim.b[buf][key] = true
  end
  vim.b[buf].snacks_animate = false
  pcall(vim.diagnostic.enable, false, { bufnr = buf })
end

return M
