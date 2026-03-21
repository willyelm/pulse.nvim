local config = require("pulse.config")

local M = {}

local function registry()
	return config.options._picker_registry or {}
end

function M.by_start()
	return config.options._by_start or {}
end

function M.parse_prompt(prompt)
	prompt = prompt or ""
	local cfg = M.by_start()[prompt:sub(1, 1)]
	if cfg then
		return cfg.mode, prompt:sub(cfg.strip)
	end
	return config.options._default_mode or "files", prompt
end

function M.switch_prompt(prompt, mode_name)
	local _, query = M.parse_prompt(prompt or "")
	local picker = registry()[mode_name]
	local prefix = picker and picker.mode and picker.mode.start or ""
	return prefix .. query
end

function M.find_by_command(name)
	for current_mode, picker in pairs(registry()) do
		if (picker.mode.command_name or current_mode) == name then
			return current_mode, nil
		end
	end
	for current_mode, picker in pairs(registry()) do
		if picker.panels then
			for _, panel in ipairs(picker.panels) do
				if panel.name == name then
					return current_mode, panel.name
				end
			end
		end
	end
end

return M
