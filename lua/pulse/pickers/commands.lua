local M = {}

local function has_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

function M.seed()
  local history = {}
  local seen = {}
  local last = vim.fn.histnr(":")
  for i = last, math.max(1, last - 250), -1 do
    local cmd = vim.fn.histget(":", i)
    if cmd ~= "" and not seen[cmd] then
      seen[cmd] = true
      history[#history + 1] = cmd
    end
  end

  local commands = {}
  seen = {}
  for _, cmd in ipairs(vim.fn.getcompletion("", "command")) do
    if cmd ~= "" and not seen[cmd] then
      seen[cmd] = true
      commands[#commands + 1] = cmd
    end
  end
  table.sort(commands)

  return { history = history, commands = commands }
end

function M.items(state, query)
  local items, seen = {}, {}
  local show_history = query == nil or query == ""

  if show_history then
    for _, cmd in ipairs(state.history) do
      if has_ci(cmd, query) then
        seen[cmd] = true
        items[#items + 1] = { kind = "command", command = cmd, source = "history" }
      end
    end
  end

  for _, cmd in ipairs(state.commands) do
    if not seen[cmd] and has_ci(cmd, query) then
      items[#items + 1] = { kind = "command", command = cmd, source = "completion" }
    end
  end

  return items
end

return M
