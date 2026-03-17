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

  if selection.kind == "code_action" then
    return M.apply_code_action(selection)
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

function M.apply_code_action(selection)
  if not selection or not selection.action then
    return false
  end

  local action = selection.action

  -- Apply workspace edit
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")
  end

  -- Execute command
  if action.command then
    local command = action.command
    if type(command) == "string" then
      vim.lsp.buf_request(0, "workspace/executeCommand", { command = command }, nil)
    else
      vim.lsp.buf_request(0, "workspace/executeCommand", command, nil)
    end
  end

  return true
end

return M
