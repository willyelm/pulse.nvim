local ui = require("pulse.ui")
local layout_mod = require("pulse.layout")

local M = {}

local defaults = {
	initial_mode = "insert",
	position = "top",
	width = 0.70,
	height = 0.50,
	border = true,
}

local session = {
	box = nil,
	layout = nil,
	lifecycle_group = nil,
	panels = { buf = nil, win = nil },
	panels_ns = vim.api.nvim_create_namespace("pulse_ui_panels"),
}

local function configure_box(navigator_opts)
	local border = (navigator_opts.border == true) and "single" or navigator_opts.border
	local row = (navigator_opts.position == "top") and 1 or nil
	if not session.box then
		session.box = ui.box.new({
			width = navigator_opts.width,
			height = navigator_opts.height,
			row = row,
			col = 0.5,
			border = border,
			focusable = true,
			zindex = 60,
			winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
		})
		session.layout = layout_mod.new(session.box)
		session.lifecycle_group = vim.api.nvim_create_augroup("PulseUIPalette" .. session.box.buf, { clear = true })
		return
	end

	session.box.opts.width = navigator_opts.width
	session.box.opts.height = navigator_opts.height
	session.box.opts.row = row
	session.box.opts.border = border
end

function session:is_visible()
	return self.box and self.box:is_valid()
end

function session:sync_handles()
	if self.box.win and not vim.api.nvim_win_is_valid(self.box.win) then
		self.box.win = nil
	end
	for _, section in pairs(self.box.sections or {}) do
		if section.win and not vim.api.nvim_win_is_valid(section.win) then
			section.win = nil
		end
	end
end

function session:hide()
	if not self:is_visible() then return end
	self.box:unmount()
	self:sync_handles()
end

function session:mount(on_resize)
	local main_win, _, mount_err = self.box:mount()
	if not main_win then
		return nil, tostring(mount_err)
	end
	vim.api.nvim_clear_autocmds({ group = self.lifecycle_group })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = self.lifecycle_group,
		pattern = tostring(self.box.win),
		once = true,
		callback = function()
			self:sync_handles()
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = self.lifecycle_group,
		callback = function()
			if not self:is_visible() then return end
			self.box:update()
			if on_resize then on_resize() end
		end,
	})

	return main_win, nil
end

function M.normalize_opts(opts)
	return vim.tbl_deep_extend("force", defaults, opts or {})
end

function M.ensure(navigator_opts)
	configure_box(M.normalize_opts(navigator_opts))
	return session
end

return M
