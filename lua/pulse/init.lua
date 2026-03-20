local config = require("pulse.config")
local picker = require("pulse.picker")
local mode = require("pulse.mode")

local M = {}

-- Public API: Utilities for picker development
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

local function open_panel(initial_prompt, extra_opts)
	if not initial_prompt or initial_prompt == "" then
		initial_prompt = vim.g.pulse_last_prompt or ""
	end
	picker.open(vim.tbl_deep_extend("force", {
		initial_prompt = initial_prompt,
	}, config.options, extra_opts or {}))
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
	local registry = config.options._picker_registry or {}

	local mode_name, picker
	if not name then
		mode_name = config.options._default_mode or "files"
		picker = registry[mode_name]
	else
		mode_name = mode.find_by_command(name)
		picker = registry[mode_name]
		if not picker then
			vim.notify("Pulse: unknown picker '" .. tostring(name) .. "'", vim.log.levels.ERROR)
			return
		end
	end

	local prefix = picker and picker.mode and picker.mode.start or ""
	open_panel(prefix)
end

function M.setup(opts)
	config.setup(opts)

	-- Build :Pulse tab-completions
	local completions = {}
	local registry = config.options._picker_registry or {}
	for mode_name in pairs(registry) do
		completions[#completions + 1] = mode_name
	end
	table.sort(completions)

	-- Re-create user command with live completions
	pcall(vim.api.nvim_del_user_command, "Pulse")
	vim.api.nvim_create_user_command("Pulse", pulse_command, {
		nargs = "?",
		complete = function()
			return completions
		end,
	})

	if config.options.cmdline then
		setup_cmdline_replacement()
	end
end

return M
