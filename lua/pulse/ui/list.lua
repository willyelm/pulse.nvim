local M = {}
local List = {}
List.__index = List
local window = require("pulse.ui.window")
local MATCH_HL = "PulseListMatch"

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

local function normalise_item(rendered)
	if type(rendered) ~= "table" then
		rendered = {}
	end
	return {
		left = tostring(rendered.left or ""),
		left_group = rendered.left_group or "Normal",
		right = tostring(rendered.right or ""),
		right_group = rendered.right_group or "Comment",
		left_matches = rendered.left_matches,
	}
end

function List.new(opts)
	local self = setmetatable({}, List)
	self.buf = assert(opts.buf, "list requires a buffer")
	self.win = assert(opts.win, "list requires a window")
	self.max_visible = opts.max_visible or 15
	self.min_visible = opts.min_visible or 3
	self.render_item = assert(opts.render_item, "list requires render_item callback")
	self.items = {}
	self.selected = 1
	self.visible_count = self.min_visible
	self.ns = vim.api.nvim_create_namespace("pulse_ui_list")
	pcall(vim.api.nvim_set_hl, 0, MATCH_HL, { bold = true, default = true })

	vim.bo[self.buf].buftype = "nofile"
	vim.bo[self.buf].bufhidden = "wipe"
	vim.bo[self.buf].swapfile = false
	vim.bo[self.buf].modifiable = false
	vim.bo[self.buf].filetype = "pulselist"

	window.configure_content_window(self.win)

	return self
end

function List:_normalise_selection()
	if #self.items == 0 then
		self.selected = 1
		return
	end

	self.selected = clamp(self.selected, 1, #self.items)
end

function List:_visible_lines(width)
	local lines = {}
	local highlights = {}
	local content_width = math.max(width or 0, 1)

	if #self.items == 0 then
		local text = "(No items)"
		local pad = math.max(content_width - vim.fn.strdisplaywidth(text), 0)
		lines[1] = text .. string.rep(" ", pad)
		highlights[1] = { group = "Comment", row = 0, start_col = 0, end_col = #text }
		while #lines < self.visible_count do
			lines[#lines + 1] = string.rep(" ", content_width)
		end
		return lines, highlights
	end

	for index, item in ipairs(self.items) do
		local spec = normalise_item(self.render_item(item, content_width))
		local left = fit_to_width(spec.left, content_width)
		local left_group = spec.left_group
		local left_matches = type(spec.left_matches) == "table" and spec.left_matches or nil
		local right = spec.right
		local right_group = spec.right_group
		local text, text_width, right_start = "", 0, nil

		if right ~= "" then
			local right_text = fit_to_width(right, content_width)
			local right_width = vim.fn.strdisplaywidth(right_text)
			local left_cap = math.max(content_width - right_width - 1, 0)
			left = fit_to_width(left, left_cap)
			local left_width = vim.fn.strdisplaywidth(left)
			local gap = math.max(content_width - left_width - right_width, 0)
			text = left .. string.rep(" ", gap) .. right_text
			text_width = vim.fn.strdisplaywidth(text)
			right_start = #left + gap
		else
			text = left
			text_width = vim.fn.strdisplaywidth(text)
		end

		local padded = text .. string.rep(" ", math.max(content_width - text_width, 0))
		lines[index] = padded

		if left_group and #left > 0 then
			highlights[#highlights + 1] = {
				group = left_group,
				row = index - 1,
				start_col = 0,
				end_col = #left,
			}
		end
		if left_matches and #left_matches > 0 then
			local left_len = #left
			for _, m in ipairs(left_matches) do
				local s = math.max(tonumber(m[1]) or -1, 0)
				local e = math.max(tonumber(m[2]) or -1, s)
				if s < left_len then
					highlights[#highlights + 1] = {
						group = m[3] or MATCH_HL,
						row = index - 1,
						start_col = s,
						end_col = math.min(e, left_len),
					}
				end
			end
		end
		if right_start and right_group and #right > 0 then
			highlights[#highlights + 1] = {
				group = right_group,
				row = index - 1,
				start_col = right_start,
				end_col = #text,
			}
		end
		if index == self.selected then
			highlights[#highlights + 1] = {
				group = "Visual",
				row = index - 1,
				start_col = 0,
				end_col = -1,
			}
		end
	end

	while #lines < self.visible_count do
		lines[#lines + 1] = string.rep(" ", content_width)
	end

	return lines, highlights
end

function List:render(width)
	window.configure_content_window(self.win)
	width = math.max(width or (self.win and vim.api.nvim_win_get_width(self.win)) or 20, 1)
	self:_normalise_selection()

	local lines, highlights = self:_visible_lines(width)
	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.bo[self.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
	for _, item in ipairs(highlights) do
		pcall(vim.api.nvim_buf_add_highlight, self.buf, self.ns, item.group, item.row, item.start_col, item.end_col)
	end

	if self.win and vim.api.nvim_win_is_valid(self.win) then
		local row = (#self.items > 0) and self.selected or 1
		pcall(vim.api.nvim_win_set_cursor, self.win, { row, 0 })
	end
end

function List:set_items(items)
	self.items = items or {}
	local count = #self.items
	self.visible_count = (count == 0) and self.min_visible or clamp(count, self.min_visible, self.max_visible)
	self:_normalise_selection()
end

function List:set_selected(index)
	self.selected = index or 1
	self:_normalise_selection()
end

function List:selected_item()
	return self.items[self.selected]
end

function List:move(delta, skip)
	if #self.items == 0 then
		return
	end

	local n = #self.items
	local step = (delta or 0) >= 0 and 1 or -1
	local start = self.selected

	for _ = 1, n do
		self.selected = self.selected + step
		if self.selected < 1 then
			self.selected = n
		elseif self.selected > n then
			self.selected = 1
		end
		local item = self.items[self.selected]
		if not skip or not skip(item) then
			return
		end
	end

	self.selected = start
end

M.new = function(opts)
	return List.new(opts)
end

return M
