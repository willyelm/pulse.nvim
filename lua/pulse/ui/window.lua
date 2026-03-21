local M = {}

function M.configure_content_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  local opts = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    foldenable = false,
    foldmethod = "manual",
    foldexpr = "0",
    foldtext = "",
    statuscolumn = "",
    conceallevel = 0,
    concealcursor = "",
    scrolloff = 0,
    sidescrolloff = 0,
    wrap = false,
    cursorline = true,
  }
  for k, v in pairs(opts) do
    vim.wo[win][k] = v
  end
end

function M.configure_isolated_buffer(buf, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  opts = opts or {}
  vim.bo[buf].buftype = opts.buftype or "nofile"
  vim.bo[buf].bufhidden = opts.bufhidden or "wipe"
  vim.bo[buf].buflisted = opts.buflisted == true
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = opts.modifiable == true
  vim.bo[buf].filetype = opts.filetype or ""
  vim.bo[buf].modified = false
  for _, key in ipairs({ "gitsigns_disable", "miniindentscope_disable", "minianimate_disable", "illuminate_disable" }) do
    vim.b[buf][key] = true
  end
  vim.b[buf].snacks_animate = false
  pcall(vim.diagnostic.enable, false, { bufnr = buf })
end

return M
