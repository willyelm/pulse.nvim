local M = {}
M.__index = M
local window = require("pulse.ui.window")
local MATCH_HL = "PulseListMatch"
local SIDE_PADDING = 1

local function clamp(value, min_value, max_value)
	return math.min(math.max(value, min_value), max_value)
end

local function fit_to_width(text, width)
	local s = tostring(text or "")
	if width <= 0 then
		return ""
	end

	local current_width = vim.fn.strdisplaywidth(s)
	if current_width <= width then
		return s
	end

	local out, out_width = {}, 0
	local idx = 0
	while true do
		local ch = vim.fn.strcharpart(s, idx, 1)
		if ch == "" then
			break
		end
		local ch_width = vim.fn.strdisplaywidth(ch)
		if out_width + ch_width > width then
			break
		end
		out[#out + 1] = ch
		out_width = out_width + ch_width
		idx = idx + 1
	end
	return table.concat(out)
end

local function add_hl(highlights, group, row, start_col, end_col)
	highlights[#highlights + 1] = { group = group, row = row, start_col = start_col, end_col = end_col }
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function normalise_item(rendered)
	if type(rendered) ~= "table" then
		rendered = {}
	end
	return {
		left = tostring(rendered.left or ""),
		left_group = (rendered.left_group == nil) and "Normal" or rendered.left_group,
		right = tostring(rendered.right or ""),
		right_group = rendered.right_group or "LineNr",
		left_matches = rendered.left_matches,
		right_matches = rendered.right_matches,
	}
end

local function normalize_hex(color)
	if type(color) ~= "string" then
		return nil
	end
	local hex = color:match("^#?([0-9a-fA-F]+)$")
	if not hex then
		return nil
	end
	if #hex == 3 then
		hex = hex:gsub(".", "%1%1")
	end
	if #hex ~= 6 then
		return nil
	end
	return "#" .. hex:upper()
end

function M.new(opts)
	local self = setmetatable({}, M)
	self.buf = assert(opts.buf, "list requires a buffer")
	self.win = assert(opts.win, "list requires a window")
	self.max_visible = opts.max_visible or 15
	self.min_visible = opts.min_visible or 3
	self.allow_empty_selection = opts.allow_empty_selection == true
	self.render_item = assert(opts.render_item, "list requires render_item callback")
	self.items = {}
	self.selected = 1
	self.visible_count = self.min_visible
	self.ns = vim.api.nvim_create_namespace("pulse_ui_list")
	self.color_hl_cache = {}
	pcall(vim.api.nvim_set_hl, 0, MATCH_HL, { bold = true, default = true })

	window.configure_isolated_buffer(self.buf, { buftype = "nofile", modifiable = false })

	window.configure_content_window(self.win)

	return self
end

function M:_match_group(match_spec)
	if type(match_spec) == "string" and match_spec ~= "" then
		return match_spec
	end
	if type(match_spec) ~= "table" then
		return MATCH_HL
	end
	local hex = normalize_hex(match_spec.fg)
	if not hex then
		return MATCH_HL
	end
	local hl = self.color_hl_cache[hex]
	if hl then
		return hl
	end
	hl = "DevIconColor_" .. hex:sub(2)
	self.color_hl_cache[hex] = hl
	pcall(vim.api.nvim_set_hl, 0, hl, { fg = hex })
	return hl
end

function M:_normalise_selection()
	local min_sel = (self.allow_empty_selection and 0 or 1)
	self.selected = clamp(self.selected or min_sel, min_sel, #self.items)
end

function M:_add_matches(highlights, row, offset, text_len, matches)
	if not matches or #matches == 0 then
		return
	end
	for _, m in ipairs(matches) do
		local s = math.max(tonumber(m[1]) or -1, 0)
		if s < text_len then
			local e = math.min(math.max(tonumber(m[2]) or -1, s), text_len)
			add_hl(highlights, self:_match_group(m[3]), row, offset + s, offset + e)
		end
	end
end

function M:_visible_lines(width)
	local lines = {}
	local highlights = {}
	local total_width = math.max(width or 0, 1)
	local content_width = math.max(total_width - (SIDE_PADDING * 2), 1)

	if #self.items == 0 then
		local text = "(No items)"
		local fit = fit_to_width(text, content_width)
		local fit_width = vim.fn.strdisplaywidth(fit)
		local pad = math.max(content_width - fit_width, 0)
		lines[1] = string.rep(" ", SIDE_PADDING) .. fit .. string.rep(" ", pad + SIDE_PADDING)
		highlights[1] = { group = "Comment", row = 0, start_col = SIDE_PADDING, end_col = SIDE_PADDING + #fit }
	else
		for index, item in ipairs(self.items) do
			local spec = normalise_item(self.render_item(item, content_width))
			local left = fit_to_width(spec.left, content_width)
			local right = spec.right
			local right_start, text = nil, left

			if right ~= "" then
				right = fit_to_width(right, content_width)
				local right_width = vim.fn.strdisplaywidth(right)
				left = fit_to_width(left, math.max(content_width - right_width - 1, 0))
				local gap = math.max(content_width - vim.fn.strdisplaywidth(left) - right_width, 0)
				text = left .. string.rep(" ", gap) .. right
				right_start = #left + gap
			end

			local padded = string.rep(" ", SIDE_PADDING)
				.. text
				.. string.rep(" ", math.max(content_width - vim.fn.strdisplaywidth(text), 0))
				.. string.rep(" ", SIDE_PADDING)
			lines[index] = padded

			if index == self.selected then
				add_hl(highlights, "Visual", index - 1, 0, #padded)
			else
				if spec.left_group and #left > 0 then
					add_hl(highlights, spec.left_group, index - 1, SIDE_PADDING, SIDE_PADDING + #left)
				end
				self:_add_matches(highlights, index - 1, SIDE_PADDING, #left, spec.left_matches)
				if right_start and spec.right_group and #right > 0 then
					add_hl(highlights, spec.right_group, index - 1, SIDE_PADDING + right_start, SIDE_PADDING + #text)
				end
				self:_add_matches(highlights, index - 1, SIDE_PADDING + (right_start or 0), #right, spec.right_matches)
			end
		end
	end

	while #lines < self.visible_count do
		lines[#lines + 1] = string.rep(" ", total_width)
	end

	return lines, highlights
end

function M:render(width)
	width = math.max(width or (self.win and vim.api.nvim_win_get_width(self.win)) or 20, 1)
	self:_normalise_selection()

	local lines, highlights = self:_visible_lines(width)
	set_lines(self.buf, lines)

	vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
	for _, item in ipairs(highlights) do
		pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, item.row, item.start_col, {
			end_row = item.row,
			end_col = item.end_col,
			hl_group = item.group,
		})
	end

	if self.win and vim.api.nvim_win_is_valid(self.win) then
		local row = ((#self.items > 0) and (self.selected or 0) > 0) and self.selected or 1
		pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
	end
end

function M:set_items(items)
	self.items = items or {}
	local count = #self.items
	self.visible_count = (count == 0) and self.min_visible or clamp(count, self.min_visible, self.max_visible)
	self:_normalise_selection()
end

function M:set_selected(index)
	self.selected = index
	self:_normalise_selection()
end

function M:selected_item()
	if (self.selected or 0) < 1 then
		return nil
	end
	return self.items[self.selected]
end

function M:set_allow_empty_selection(allow)
	self.allow_empty_selection = allow == true
	self:_normalise_selection()
end

function M:move(delta, skip)
	if #self.items == 0 then
		return
	end

	local n = #self.items
	local step = (delta or 0) >= 0 and 1 or -1
	local start = self.selected

	for _ = 1, n do
		self.selected = ((self.selected - 1 + step) % n) + 1
		local item = self.items[self.selected]
		if not skip or not skip(item) then
			return
		end
	end

	self.selected = start
end

return M
