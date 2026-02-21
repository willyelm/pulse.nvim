local M = {}

function M.jump_to(selection)
  local function edit_target(path)
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      vim.notify(tostring(err), vim.log.levels.WARN)
      return false
    end
    return true
  end

  if selection.kind == "file" then
    return edit_target(selection.path)
  end

  if selection.kind == "command" then
    local keys = vim.api.nvim_replace_termcodes(":" .. selection.command, true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
    return true
  end

  if selection.filename and selection.filename ~= "" then
    if not edit_target(selection.filename) then
      return false
    end
  end

  if selection.lnum then
    vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
  end

  return true
end

function M.execute_command(cmd)
  local ex = vim.trim(cmd or "")
  if ex == "" then
    return
  end
  local ok, err = pcall(vim.cmd, ex)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

function M.is_jumpable(item)
  return item
    and (
      item.kind == "symbol"
      or item.kind == "workspace_symbol"
      or item.kind == "file"
      or item.kind == "live_grep"
      or item.kind == "fuzzy_search"
    )
end

return M
