local M = {}
local util = require("pulse.util")

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
  query = query or ""
  local match = util.make_matcher(query, { ignore_case = true, plain = true })
  local items, seen = {}, {}
  local show_history = query == ""

  if show_history then
    for _, cmd in ipairs(state.history) do
      if match(cmd) then
        seen[cmd] = true
        items[#items + 1] = { kind = "command", command = cmd }
      end
    end
  end

  for _, cmd in ipairs(state.commands) do
    if not seen[cmd] and match(cmd) then
      items[#items + 1] = { kind = "command", command = cmd }
    end
  end

  return items
end

return M
