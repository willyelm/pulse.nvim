local M = {}

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

function M.resolve_max_height(height_cfg)
	local total = vim.o.lines - vim.o.cmdheight
	local h = type(height_cfg) == "number" and height_cfg or 0.5
	return math.max((h > 0 and h < 1) and math.floor(total * h) or math.floor(h), 6)
end

function M.new(box)
	local layout = { sections = {}, last_dims = {} }

	local function upsert(name, opts)
		local current = layout.sections[name]
		if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then
			opts.buf = current.buf
		end
		layout.sections[name] = box:create_section(name, opts)
		return layout.sections[name]
	end

	local function draw_divider(buf, width)
		set_lines(buf, { string.rep("─", width) })
	end

	function layout:apply(body_height, preview_height, refs)
		local width = vim.api.nvim_win_get_width(box.win)
		local show_preview = preview_height > 0
		local show_panels = refs and refs.show_panels == true
		if
			self.sections.input
			and self.last_dims.body == body_height
			and self.last_dims.preview == preview_height
			and self.last_dims.width == width
			and self.last_dims.panels == show_panels
		then
			return
		end

		local chrome_height = 2 + (show_panels and 2 or 0) + (show_preview and 1 + preview_height or 0)
		box:update({ height = body_height + chrome_height })
		width = vim.api.nvim_win_get_width(box.win)

		local specs = {
			{ name = "input", row = 0, height = 1, focusable = true, winhl = "Normal:NormalFloat" },
			{ name = "divider", row = 1, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true },
		}

		local list_row = 2
		if show_panels then
			specs[#specs + 1] = { name = "panels", row = 2, height = 1, focusable = false, winhl = "Normal:NormalFloat" }
			specs[#specs + 1] = { name = "panel_divider", row = 3, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true }
			list_row = 4
		else
			box:close_section("panels")
			box:close_section("panel_divider")
			self.sections.panels = nil
			self.sections.panel_divider = nil
		end

		specs[#specs + 1] = {
			name = "list",
			row = list_row,
			height = body_height,
			focusable = true,
			winhl = "Normal:NormalFloat,CursorLine:CursorLine",
		}

		if show_preview then
			specs[#specs + 1] = { name = "body_divider", row = list_row + body_height, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true }
			specs[#specs + 1] = { name = "preview", row = list_row + body_height + 1, height = preview_height, focusable = true, winhl = "Normal:NormalFloat" }
		else
			box:close_section("body_divider")
			box:close_section("preview")
			self.sections.body_divider, self.sections.preview = nil, nil
		end

		for _, s in ipairs(specs) do
			local section = upsert(s.name, {
				row = s.row,
				col = 0,
				width = width,
				height = s.height,
				focusable = s.focusable,
				enter = false,
				winhl = s.winhl,
			})
			if s.divider then
				draw_divider(section.buf, width)
			end
		end

		if refs.list then
			refs.list.win = self.sections.list.win
		end
		if refs.panels then
			refs.panels.buf = show_panels and self.sections.panels.buf or nil
			refs.panels.win = show_panels and self.sections.panels.win or nil
		end
		if refs.input then
			refs.input:set_win(self.sections.input.win)
		end
		if refs.preview then
			local buf = show_preview and self.sections.preview.buf or nil
			local win = show_preview and self.sections.preview.win or nil
			refs.preview:set_target(buf, win)
		end

		self.last_dims = { body = body_height, preview = preview_height, width = width, panels = show_panels }
	end

	return layout
end

return M
