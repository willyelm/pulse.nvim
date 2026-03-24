local M = {
	defaults = {
		cmdline = false,
		position = "top",
		width = 0.50,
		height = 0.75,
		border = "rounded",
		navigators = {
			"files",
			"commands",
			"git",
			"diagnostics",
			"code_actions",
			"symbols",
			"live_grep",
			"fuzzy_search",
		},
	},
}
M.options = M.defaults

local state = {
	navigator_options = {},
	navigator_registry = {},
	by_start = {},
	default_navigator = nil,
}

local function navigator_config(opts)
	local configured = opts and opts.navigators
	local per_navigator = vim.deepcopy((opts and opts.navigator_options) or {})
	if configured == nil then
		return M.defaults.navigators, per_navigator
	end
	if vim.islist(configured) then
		return configured, per_navigator
	end
	if type(configured) ~= "table" then
		return M.defaults.navigators, per_navigator
	end

	local resolved = {}
	local added = {}
	for _, name in ipairs(M.defaults.navigators) do
		local entry = configured[name]
		if entry ~= false then
			resolved[#resolved + 1] = name
			added[name] = true
			if type(entry) == "table" then
				per_navigator[name] = vim.tbl_deep_extend("force", per_navigator[name] or {}, entry)
			end
		end
	end
	for name, entry in pairs(configured) do
		if type(name) == "string" and not added[name] and entry ~= false then
			resolved[#resolved + 1] = name
			if type(entry) == "table" then
				per_navigator[name] = vim.tbl_deep_extend("force", per_navigator[name] or {}, entry)
			end
		end
	end
	return resolved, per_navigator
end

function M.for_navigator(mode_name)
	return state.navigator_options[mode_name] or {}
end

function M.registry()
	return state.navigator_registry
end

function M.by_start()
	return state.by_start
end

function M.default_navigator()
	return state.default_navigator or "files"
end

function M.parse_prompt(prompt)
	prompt = prompt or ""
	local entry = state.by_start[prompt:sub(1, 1)]
	if entry then
		return entry.navigator, prompt:sub(entry.strip)
	end
	return M.default_navigator(), prompt
end

function M.switch_prompt(prompt, navigator_name)
	local _, query = M.parse_prompt(prompt or "")
	local navigator = state.navigator_registry[navigator_name]
	local prefix = navigator and navigator.panels and navigator.panels[1] and navigator.panels[1].start or ""
	return prefix .. query
end

function M.find_by_command(name)
	for navigator_name, navigator in pairs(state.navigator_registry) do
		if (navigator.command_name or navigator_name) == name then
			return navigator_name, nil
		end
	end
	for navigator_name, navigator in pairs(state.navigator_registry) do
		for _, panel in ipairs(navigator.panels or {}) do
			if panel.name == name then
				return navigator_name, panel.name
			end
		end
	end
end

function M.setup(opts)
	local navigators_config, per_navigator = navigator_config(opts)
	local safe_opts = opts and vim.tbl_extend("force", {}, opts) or {}
	safe_opts.navigators = nil
	safe_opts.navigator_options = nil
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), safe_opts)

	local navigators = {}
	local registry = {}
	local by_start = {}
	local default_navigator = nil

	for _, p in ipairs(navigators_config) do
		local navigator_module
		if type(p) == "string" then
			local ok, mod = pcall(require, "pulse.navigators." .. p)
			if ok and mod then
				navigator_module = mod
			else
				vim.notify("Pulse: failed to load navigator '" .. p .. "'", vim.log.levels.WARN)
			end
		elseif type(p) == "table" then
			navigator_module = p
		else
			vim.notify("Pulse: invalid navigator entry (must be string name or module)", vim.log.levels.WARN)
		end

		if
			navigator_module
			and navigator_module.name
			and type(navigator_module.init) == "function"
			and type(navigator_module.items) == "function"
		then
			local navigator_name = navigator_module.name
			if registry[navigator_name] then
				vim.notify("Pulse: duplicate navigator name '" .. navigator_name .. "'", vim.log.levels.WARN)
			else
				navigators[#navigators + 1] = navigator_module
				registry[navigator_name] = navigator_module

				if not (navigator_module.panels and #navigator_module.panels > 0) then
					vim.notify("Pulse: navigator '" .. navigator_name .. "' must define panels", vim.log.levels.WARN)
				end
				for _, entry in ipairs(navigator_module.panels or {}) do
					local start = entry.start or ""
					if start ~= "" then
						if by_start[start] and by_start[start].navigator ~= navigator_name then
							vim.notify(
								"Pulse: prefix '"
									.. start
									.. "' already taken, ignoring panel '"
									.. tostring(entry.name)
									.. "'",
								vim.log.levels.WARN
							)
						else
							by_start[start] = { navigator = navigator_name, strip = #start + 1 }
						end
					elseif not default_navigator then
						default_navigator = navigator_name
					end
				end
			end
		else
			vim.notify("Pulse: invalid navigator entry in navigator list", vim.log.levels.WARN)
		end
	end

	M.options.navigators = navigators
	state.navigator_options = per_navigator
	state.navigator_registry = registry
	state.by_start = by_start
	state.default_navigator = default_navigator
end

return M
