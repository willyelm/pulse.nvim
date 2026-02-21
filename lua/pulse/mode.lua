local M = {}

local MODE_PREFIX = {
  [":"] = { mode = "commands", strip = 2 },
  ["~"] = { mode = "git_status", strip = 2 },
  ["!"] = { mode = "diagnostics", strip = 2 },
  ["@"] = { mode = "symbol", strip = 2 },
  ["#"] = { mode = "workspace_symbol", strip = 2 },
  ["$"] = { mode = "live_grep", strip = 2 },
}

function M.parse_prompt(prompt)
  prompt = prompt or ""
  local cfg = MODE_PREFIX[prompt:sub(1, 1)]
  if cfg then
    return cfg.mode, prompt:sub(cfg.strip)
  end
  return "files", prompt
end

return M
