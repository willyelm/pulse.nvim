local M = {}

M.MODES = {
	files = { start = "", icon = "󰈔", placeholder = "Search Files", strip = 1, preview = false },
	commands = { start = ":", icon = "", placeholder = "Run Command", strip = 2, preview = false },
	git_status = { start = "~", icon = "󰊢", placeholder = "Search Git Status", strip = 2, preview = true },
	diagnostics = { start = "!", icon = "", placeholder = "Search Diagnostics", strip = 2, preview = true },
	symbol = { start = "@", icon = "󰘧", placeholder = "Search Symbols In Current Buffer", strip = 2, preview = false },
	workspace_symbol = { start = "#", icon = "󰒕", placeholder = "Search Workspace Symbols", strip = 2, preview = false },
	live_grep = { start = "$", icon = "󰍉", placeholder = "Live Grep In Project", strip = 2, preview = true },
	fuzzy_search = { start = "?", icon = "󱉶", placeholder = "Fuzzy Search In Current Buffer", strip = 2, preview = true },
}

local BY_START = {}
for mode, cfg in pairs(M.MODES) do
	if cfg.start and cfg.start ~= "" then
		BY_START[cfg.start] = { mode = mode, strip = cfg.strip }
	end
end

function M.mode(mode_name)
	return M.MODES[mode_name] or M.MODES.files
end

function M.start(mode_name)
	return M.mode(mode_name).start or ""
end

function M.icon(mode_name)
	return M.mode(mode_name).icon or ""
end

function M.placeholder(mode_name)
	return M.mode(mode_name).placeholder or ""
end

function M.preview(mode_name)
	return M.mode(mode_name).preview == true
end

function M.starts()
	local out = {}
	for start in pairs(BY_START) do
		out[start] = true
	end
	return out
end

function M.parse_prompt(prompt)
	prompt = prompt or ""
	local cfg = BY_START[prompt:sub(1, 1)]
	if cfg then
		return cfg.mode, prompt:sub(cfg.strip)
	end
	return "files", prompt
end

return M
