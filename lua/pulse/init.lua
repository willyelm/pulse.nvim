local config = require("pulse.config")
local navigator = require("pulse.navigator")
local mode = require("pulse.mode")
local panel = require("pulse.panel")
local scope = require("pulse.scope")

local M = {}

local function registry()
	return config.options._navigator_registry or {}
end

function M.make_matcher(query, opts)
	opts = opts or {}
	local needle = tostring(query or "")
	if opts.trim then needle = vim.trim(needle) end
	local ignore_case = opts.ignore_case ~= false
	if ignore_case then needle = string.lower(needle) end
	local plain = opts.plain ~= false
	local empty = needle == ""
	return function(haystack)
		if empty then return true end
		local h = tostring(haystack or "")
		if ignore_case then h = string.lower(h) end
		return string.find(h, needle, 1, plain) ~= nil
	end, needle
end

function M.filetype_for(path)
	local ft = vim.filetype.match({ filename = path or "" })
	if ft and ft ~= "" then return ft end
	ft = vim.fn.fnamemodify(path or "", ":e")
	return (ft ~= "" and ft) or "file"
end

local function open_panel(initial_prompt, extra_opts, initial_panel)
	navigator.open(vim.tbl_deep_extend("force", config.options, extra_opts or {}, {
		initial_prompt = initial_prompt,
		initial_panel = initial_panel,
	}))
end

local function setup_cmdline_replacement()
	vim.o.cmdheight = 0
	local open_colon = function() open_panel(":") end
	vim.keymap.set({ "n", "x", "o" }, ":", open_colon, { noremap = true, silent = true, desc = "Pulse Cmdline" })
	vim.keymap.set("n", "q:", open_colon, { noremap = true, silent = true, desc = "Pulse Cmdline Window" })
	local group = vim.api.nvim_create_augroup("PulseCmdlineReplace", { clear = true })
	vim.api.nvim_create_autocmd("CmdlineEnter", {
		group = group,
		pattern = ":",
		callback = function()
			vim.schedule(function()
				if vim.fn.mode() ~= "c" or vim.fn.getcmdtype() ~= ":" then
					return
				end
				local line = vim.fn.getcmdline()
				local esc = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
				vim.api.nvim_feedkeys(esc, "n", false)
				open_panel(":" .. line)
			end)
		end,
	})
end

local function pulse_command(opts)
	local name = (opts and opts.args and opts.args ~= "") and opts.args or nil
	if not name then
		navigator.toggle(config.options)
		return
	end

	local mode_name, panel_name = mode.find_by_command(name)
	if not registry()[mode_name] then
		vim.notify("Pulse: unknown navigator '" .. tostring(name) .. "'", vim.log.levels.ERROR)
		return
	end
	local next_prompt = mode.switch_prompt(navigator.get_prompt() or "", mode_name)
	local extra_opts = nil
	if panel.is_buffer_only(registry()[mode_name]) then
		local current_scope = scope.from_buffer()
		if current_scope then
			extra_opts = { scope = current_scope }
		end
	end
	open_panel(next_prompt, extra_opts, panel_name)
end

function M.setup(opts)
	config.setup(opts)

	local completions = {}
	for mode_name, navigator_module in pairs(registry()) do
		completions[#completions + 1] = mode_name
		if navigator_module.panels then
			for _, panel in ipairs(navigator_module.panels) do
				completions[#completions + 1] = panel.name
			end
		end
	end
	table.sort(completions)

	pcall(vim.api.nvim_del_user_command, "Pulse")
	vim.api.nvim_create_user_command("Pulse", pulse_command, {
		nargs = "?",
		complete = function() return completions end,
	})

	if config.options.cmdline then
		setup_cmdline_replacement()
	end
	local files = registry().files
	if files and type(files.setup_directory_hijack) == "function" then
		files.setup_directory_hijack({
			is_enabled = function()
				return config.for_navigator("files").open_on_directory == true
			end,
			open = function(path)
				open_panel(mode.switch_prompt("", "files"), { cwd = path })
			end,
		})
	end
end

return M
