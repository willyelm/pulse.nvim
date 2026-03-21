local M = {
	defaults = {
		cmdline = false,
		initial_mode = "insert",
		position = "top",
		width = 0.50,
		height = 0.75,
		border = "rounded",
		navigators = {
			"files",
			"commands",
			"git_status",
			"diagnostics",
			"code_actions",
			"symbols",
			"workspace_symbols",
			"live_grep",
			"fuzzy_search",
		},
	},
}
M.options = M.defaults

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
	local per_navigator = M.options._navigator_options or {}
	return per_navigator[mode_name] or {}
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
	local default_mode = nil

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

		if navigator_module and navigator_module.mode and navigator_module.mode.name and type(navigator_module.init) == "function" and type(navigator_module.items) == "function" then
			local mode_name = navigator_module.mode.name
			if registry[mode_name] then
				vim.notify("Pulse: duplicate navigator name '" .. mode_name .. "'", vim.log.levels.WARN)
			else
				navigators[#navigators + 1] = navigator_module
				registry[mode_name] = navigator_module

				if not (navigator_module.panels and #navigator_module.panels > 0) then
					vim.notify("Pulse: navigator '" .. mode_name .. "' must define panels", vim.log.levels.WARN)
				end
				for _, entry in ipairs(navigator_module.panels or {}) do
					local start = entry.start or ""
					if start ~= "" then
						if by_start[start] then
							vim.notify("Pulse: prefix '" .. start .. "' already taken, ignoring panel '" .. tostring(entry.name) .. "'", vim.log.levels.WARN)
						else
							by_start[start] = { mode = mode_name, strip = #start + 1 }
						end
					elseif not default_mode then
						default_mode = mode_name
					end
				end
			end
		else
			vim.notify("Pulse: invalid navigator entry in navigator list", vim.log.levels.WARN)
		end
	end

	M.options.navigators = navigators
	M.options._navigator_options = per_navigator
	M.options._navigator_registry = registry
	M.options._by_start = by_start
	M.options._default_mode = default_mode
end

return M
