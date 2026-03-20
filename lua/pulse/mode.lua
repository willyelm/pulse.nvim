local config = require("pulse.config")

return {
	parse_prompt = function(prompt)
		prompt = prompt or ""
		local by_start = config.options._by_start or {}
		local cfg = by_start[prompt:sub(1, 1)]
		if cfg then
			return cfg.mode, prompt:sub(cfg.strip)
		end
		return config.options._default_mode or "files", prompt
	end,

	find_by_command = function(name)
		local registry = config.options._picker_registry or {}
		-- First try exact mode match
		for mode_name, picker in pairs(registry) do
			if (picker.mode.command_name or mode_name) == name then
				return mode_name, nil
			end
		end
		-- Try panel match
		for mode_name, picker in pairs(registry) do
			if picker.panels then
				for _, panel in ipairs(picker.panels) do
					if panel.name == name then
						return mode_name, panel.name
					end
				end
			end
		end
	end,

	by_start = function()
		return config.options._by_start or {}
	end,
}
