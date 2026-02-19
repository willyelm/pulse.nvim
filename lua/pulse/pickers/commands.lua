local common = require("pulse.pickers.common")

local M = {}

function M.title()
  return "Commands"
end

function M.seed()
  local history = {}
  local seen = {}
  local last = vim.fn.histnr(":")
  for i = last, math.max(1, last - 250), -1 do
    local c = vim.fn.histget(":", i)
    if c ~= "" and not seen[c] then
      seen[c] = true
      table.insert(history, c)
    end
  end

  local commands = {}
  seen = {}
  for _, c in ipairs(vim.fn.getcompletion("", "command")) do
    if c ~= "" and not seen[c] then
      seen[c] = true
      table.insert(commands, c)
    end
  end
  table.sort(commands)

  return { history = history, commands = commands }
end

function M.items(state, query)
  local items = {}
  local seen = {}

  for _, c in ipairs(state.history) do
    if common.has_ci(c, query) then
      seen[c] = true
      table.insert(items, { kind = "command", command = c, source = "history" })
    end
  end

  for _, c in ipairs(state.commands) do
    if not seen[c] and common.has_ci(c, query) then
      table.insert(items, { kind = "command", command = c, source = "completion" })
    end
  end

  return items
end

return M
