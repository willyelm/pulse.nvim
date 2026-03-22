local config = require("pulse.config")

local M = {}

function M.by_start()
	return config.by_start()
end

function M.parse_prompt(prompt)
	prompt = prompt or ""
	local cfg = M.by_start()[prompt:sub(1, 1)]
	if cfg then
		return cfg.mode, prompt:sub(cfg.strip)
	end
	return config.default_mode(), prompt
end

function M.switch_prompt(prompt, mode_name)
	local _, query = M.parse_prompt(prompt or "")
	local navigator = config.registry()[mode_name]
	local prefix = navigator and navigator.panels and navigator.panels[1] and navigator.panels[1].start or ""
	return prefix .. query
end

function M.find_by_command(name)
	for current_mode, navigator in pairs(config.registry()) do
		if (navigator.mode.command_name or current_mode) == name then
			return current_mode, nil
		end
	end
	for current_mode, navigator in pairs(config.registry()) do
		if navigator.panels then
			for _, panel in ipairs(navigator.panels) do
				if panel.name == name then
					return current_mode, panel.name
				end
			end
		end
	end
end

return M
