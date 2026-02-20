--- Standalone floating-window picker UI.
--- Single unified box with horizontal dividers separating prompt, list, and
--- preview panels.  All three panels are borderless inner windows layered
--- on top of a hand-drawn frame buffer.
local M = {}

local ns       = vim.api.nvim_create_namespace("pulse_window")
local frame_ns = vim.api.nvim_create_namespace("pulse_frame")

-- Box-drawing character sets keyed by border-style name.
local BOX = {
  rounded = { tl="╭", tr="╮", bl="╰", br="╯", h="─", v="│", ml="├", mr="┤" },
  single  = { tl="┌", tr="┐", bl="└", br="┘", h="─", v="│", ml="├", mr="┤" },
  double  = { tl="╔", tr="╗", bl="╚", br="╝", h="═", v="║", ml="╠", mr="╣" },
}
local MAX_LIST    = 15
local MAX_PREVIEW = 5

--- @param opts table  { width, height, border, initial_prompt, title }
--- @param callbacks table {
---   on_prompt_change(prompt),
---   on_select(entry, prompt),
---   on_preview(entry, prompt, list_win),
---   on_cursor_move(entry, prompt, controller),
---   on_close(),
--- }
--- @return table controller {
---   update(entries, title), get_prompt(), close(),
---   show_preview(content), hide_preview(),
---   results_win,
--- }
function M.open(opts, callbacks)
  opts      = opts or {}
  callbacks = callbacks or {}

  local width_frac  = opts.width  or 0.70
  local border_name = (opts.border == false) and "none"
    or (type(opts.border) == "string" and opts.border)
    or "rounded"
  local box         = BOX[border_name] or BOX.rounded
  local title       = opts.title          or "Pulse"
  local initial_prompt = opts.initial_prompt or ""

  -- inner_w: usable columns inside the frame (excludes the two side chars).
  local inner_w  = math.floor(vim.o.columns * width_frac)
  local frame_w  = inner_w + 2
  local base_col = math.floor((vim.o.columns - frame_w) / 2)
  local base_row = math.floor(vim.o.lines * 0.12)

  -- Dynamic heights – updated as content changes.
  local list_h    = 1
  local preview_h = 0

  -- ── helpers: absolute row positions inside the frame ─────────────────────
  local function prompt_abs_row()  return base_row + 1 end
  local function list_abs_row()   return base_row + 3 end   -- top + prompt + divider
  local function preview_abs_row() return base_row + 3 + list_h + 1 end  -- top + prompt + divider + list

  local function frame_height()
    return 1 + 1 + 1 + list_h
      + (preview_h > 0 and (1 + preview_h) or 0)
      + 1
  end

  -- ── buffers ───────────────────────────────────────────────────────────────
  local function scratch_buf()
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].buftype  = "nofile"
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].swapfile = false
    return b
  end

  local frame_buf   = scratch_buf()
  local prompt_buf  = scratch_buf()
  local list_buf    = scratch_buf()
  local preview_buf = scratch_buf()
  vim.bo[list_buf].modifiable    = false
  vim.bo[preview_buf].modifiable = false

  -- ── frame drawing ─────────────────────────────────────────────────────────
  local function draw_frame()
    local title_dw  = vim.fn.strdisplaywidth(title)
    local h_part    = box.h .. " " .. title .. " "
    local remain    = math.max(0, inner_w - 3 - title_dw)  -- inner_w - ("─ " + title + " ")
    local top       = box.tl .. h_part .. string.rep(box.h, remain) .. box.tr
    local div       = box.ml .. string.rep(box.h, inner_w) .. box.mr
    local side      = box.v  .. string.rep(" ", inner_w) .. box.v
    local bot       = box.bl .. string.rep(box.h, inner_w) .. box.br

    local lines = { top, side, div }
    for _ = 1, list_h do
      lines[#lines + 1] = side
    end
    if preview_h > 0 then
      lines[#lines + 1] = div
      for _ = 1, preview_h do
        lines[#lines + 1] = side
      end
    end
    lines[#lines + 1] = bot

    vim.bo[frame_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(frame_buf, frame_ns, 0, -1)
    vim.api.nvim_buf_set_lines(frame_buf, 0, -1, false, lines)
    vim.bo[frame_buf].modifiable = false

    -- Highlight title text with FloatTitle
    local prefix_bytes = #box.tl + #box.h + 1  -- e.g. "╭─ " = 7 bytes
    pcall(vim.api.nvim_buf_add_highlight,
      frame_buf, frame_ns, "FloatTitle", 0, prefix_bytes, prefix_bytes + #title)
  end

  -- ── window creation helpers ───────────────────────────────────────────────
  local function win_opts(r, c, w, h, focusable, z)
    return {
      relative  = "editor",
      row = r, col = c, width = w, height = h,
      style     = "minimal",
      border    = "none",
      focusable = focusable,
      zindex    = z,
      noautocmd = true,
    }
  end

  local function setup_win(win, hl)
    vim.api.nvim_set_option_value("winhl",      hl,    { win = win })
    vim.api.nvim_set_option_value("signcolumn", "no",  { win = win })
    vim.api.nvim_set_option_value("wrap",       false, { win = win })
    vim.api.nvim_set_option_value("scrolloff",  0,     { win = win })
    vim.api.nvim_set_option_value("sidescrolloff", 0,  { win = win })
  end

  draw_frame()

  local frame_win = vim.api.nvim_open_win(frame_buf, false,
    win_opts(base_row, base_col, frame_w, frame_height(), false, 49))
  vim.api.nvim_set_option_value("winhl", "Normal:FloatBorder", { win = frame_win })

  local prompt_win = vim.api.nvim_open_win(prompt_buf, true,
    win_opts(prompt_abs_row(), base_col + 1, inner_w, 1, true, 50))
  setup_win(prompt_win, "Normal:Normal")

  local list_win = vim.api.nvim_open_win(list_buf, false,
    win_opts(list_abs_row(), base_col + 1, inner_w, list_h, false, 50))
  setup_win(list_win, "Normal:Normal,CursorLine:CursorLine")
  vim.api.nvim_set_option_value("cursorline", true, { win = list_win })

  local preview_win = nil  -- created on demand

  -- ── state ─────────────────────────────────────────────────────────────────
  local entries = {}
  local closed  = false
  local controller  -- forward-declared; assigned at end of M.open

  -- ── prompt ────────────────────────────────────────────────────────────────
  local function get_prompt()
    if not vim.api.nvim_buf_is_valid(prompt_buf) then return "" end
    return (vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false))[1] or ""
  end

  -- ── close ─────────────────────────────────────────────────────────────────
  local function close()
    if closed then return end
    closed = true
    for _, w in ipairs({ preview_win, list_win, prompt_win, frame_win }) do
      if w and vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    for _, b in ipairs({ preview_buf, list_buf, prompt_buf, frame_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    if callbacks.on_close then pcall(callbacks.on_close) end
  end

  -- ── frame resize ──────────────────────────────────────────────────────────
  local function resize_frame()
    pcall(vim.api.nvim_win_set_config, frame_win, {
      relative = "editor",
      row = base_row, col = base_col,
      width = frame_w, height = frame_height(),
    })
    draw_frame()
  end

  -- ── list resize ───────────────────────────────────────────────────────────
  local function resize_list(new_h)
    if new_h == list_h then return end
    list_h = new_h
    pcall(vim.api.nvim_win_set_config, list_win, {
      relative = "editor",
      row = list_abs_row(), col = base_col + 1,
      width = inner_w, height = list_h,
    })
    -- Reposition preview_win when it exists (preview_abs_row depends on list_h)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_set_config, preview_win, {
        relative = "editor",
        row = preview_abs_row(), col = base_col + 1,
        width = inner_w, height = preview_h,
      })
    end
    resize_frame()
  end

  -- ── cursor helpers ────────────────────────────────────────────────────────
  local function skip_to_selectable(idx, dir)
    dir = (dir and dir < 0) and -1 or 1
    local guard = 0
    while entries[idx] and entries[idx].kind == "header" and guard < #entries do
      idx = idx + dir
      guard = guard + 1
    end
    return math.max(1, math.min(idx, #entries))
  end

  local function get_cursor_idx()
    if not vim.api.nvim_win_is_valid(list_win) then return 1 end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, list_win)
    return ok and cur[1] or 1
  end

  local function set_cursor(idx)
    if not vim.api.nvim_win_is_valid(list_win) or #entries == 0 then return end
    pcall(vim.api.nvim_win_set_cursor, list_win, { math.max(1, math.min(idx, #entries)), 0 })
  end

  local function get_selected_entry()
    return entries[get_cursor_idx()]
  end

  local function fire_cursor_move(entry)
    if not callbacks.on_cursor_move then return end
    if entry and entry.kind ~= "header" then
      pcall(callbacks.on_cursor_move, entry, get_prompt(), controller)
    else
      pcall(callbacks.on_cursor_move, nil,   get_prompt(), controller)
    end
  end

  -- ── render (list) ─────────────────────────────────────────────────────────
  local function render(new_entries)
    entries = new_entries or {}
    if not vim.api.nvim_buf_is_valid(list_buf) then return end

    local lines           = {}
    local all_highlights  = {}

    for i, entry in ipairs(entries) do
      local text, hls
      if type(entry.display) == "function" then
        text, hls = entry.display(inner_w)
      end
      lines[i]          = text or entry.ordinal or ""
      all_highlights[i] = hls or {}
    end

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for i, hls in ipairs(all_highlights) do
      for _, hl in ipairs(hls) do
        pcall(vim.api.nvim_buf_add_highlight, list_buf, ns, hl[1], i - 1, hl[3], hl[4])
      end
    end

    -- Adapt list height to content (1–MAX_LIST lines)
    resize_list(math.max(1, math.min(MAX_LIST, #entries)))

    if #entries > 0 then
      local first = skip_to_selectable(1, 1)
      set_cursor(first)
      fire_cursor_move(entries[first])
    else
      fire_cursor_move(nil)
    end
  end

  -- ── preview panel ─────────────────────────────────────────────────────────
  local function hide_preview()
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_close, preview_win, true)
      preview_win = nil
    end
    if preview_h ~= 0 then
      preview_h = 0
      resize_frame()
    end
  end

  --- content: result of preview.content_for()
  local function show_preview(content)
    if not content or #(content.lines or {}) == 0 then
      hide_preview()
      return
    end

    local new_h = math.min(MAX_PREVIEW, #content.lines)

    -- Create or reposition preview window
    if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
      preview_win = vim.api.nvim_open_win(preview_buf, false,
        win_opts(preview_abs_row(), base_col + 1, inner_w, new_h, false, 50))
      setup_win(preview_win, "Normal:Normal")
      -- Clean up if the user somehow closes it directly
      vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(preview_win),
        once = true,
        callback = function()
          preview_win = nil
          if not closed then preview_h = 0; resize_frame() end
        end,
      })
    elseif new_h ~= preview_h then
      pcall(vim.api.nvim_win_set_config, preview_win, {
        relative = "editor",
        row = preview_abs_row(), col = base_col + 1,
        width = inner_w, height = new_h,
      })
    end

    local changed = new_h ~= preview_h
    preview_h = new_h
    if changed then resize_frame() end

    -- Write lines to preview buffer
    local disp = {}
    for i = 1, preview_h do disp[i] = content.lines[i] or "" end

    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, disp)
    vim.bo[preview_buf].modifiable = false
    pcall(function()
      if content.ft then vim.bo[preview_buf].filetype = content.ft end
    end)

    -- Position cursor and apply match highlight
    local match_row = math.min(content.match_row or 0, preview_h - 1)
    pcall(vim.api.nvim_win_set_cursor, preview_win, { match_row + 1, 0 })
    if content.hl_col_start then
      pcall(vim.api.nvim_buf_add_highlight, preview_buf, ns, "Search",
        match_row, content.hl_col_start, content.hl_col_end or -1)
    end
  end

  -- ── public update ─────────────────────────────────────────────────────────
  local function update(new_entries, new_title)
    render(new_entries)
    if new_title and new_title ~= title then
      title = new_title
      draw_frame()  -- title lives in the frame, not a Neovim window title
    end
  end

  -- ── navigation ────────────────────────────────────────────────────────────
  local function move_selection(dir)
    if #entries == 0 then return end
    local idx = skip_to_selectable(get_cursor_idx() + dir, dir)
    idx = math.max(1, math.min(idx, #entries))
    set_cursor(idx)
    fire_cursor_move(entries[idx])
  end

  local function do_select()
    local entry  = get_selected_entry()
    local prompt = get_prompt()
    close()
    if callbacks.on_select then pcall(callbacks.on_select, entry, prompt) end
  end

  local function do_preview()
    local entry = get_selected_entry()
    if not entry then return end
    if entry.kind == "header" then move_selection(1); return end
    if callbacks.on_preview then
      pcall(callbacks.on_preview, entry, get_prompt(), list_win)
    end
  end

  -- ── initial prompt text ───────────────────────────────────────────────────
  if initial_prompt ~= "" then
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { initial_prompt })
  end

  -- ── keymaps ───────────────────────────────────────────────────────────────
  local map_opts = { noremap = true, silent = true, nowait = true, buffer = prompt_buf }
  local function imap(lhs, fn) vim.keymap.set("i", lhs, fn, map_opts) end
  local function nmap(lhs, fn) vim.keymap.set("n", lhs, fn, map_opts) end

  imap("<CR>",  do_select)
  nmap("<CR>",  do_select)

  imap("<Down>",  function() move_selection(1)  end)
  imap("<C-n>",   function() move_selection(1)  end)
  imap("<Tab>",   do_preview)
  imap("<Up>",    function() move_selection(-1) end)
  imap("<C-p>",   function() move_selection(-1) end)
  imap("<Esc>",   close)
  imap("<C-c>",   close)

  nmap("j",       function() move_selection(1)  end)
  nmap("<Down>",  function() move_selection(1)  end)
  nmap("<C-n>",   function() move_selection(1)  end)
  nmap("<Tab>",   do_preview)
  nmap("k",       function() move_selection(-1) end)
  nmap("<Up>",    function() move_selection(-1) end)
  nmap("<C-p>",   function() move_selection(-1) end)
  nmap("<Esc>",   close)
  nmap("<C-c>",   close)
  nmap("q",       close)

  -- ── autocmds ──────────────────────────────────────────────────────────────
  -- Dismiss any completion popup a plugin may open inside the prompt.
  vim.api.nvim_create_autocmd("CompleteChanged", {
    buffer = prompt_buf,
    callback = function()
      if closed then return end
      if vim.fn.pumvisible() == 1 then
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "n", true)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = prompt_buf,
    callback = function()
      if closed then return end
      if callbacks.on_prompt_change then
        pcall(callbacks.on_prompt_change, get_prompt())
      end
    end,
  })

  -- Closing either the prompt or frame window tears down everything.
  for _, win_id in ipairs({ prompt_win, frame_win }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win_id),
      once = true,
      callback = close,
    })
  end

  -- ── startup ───────────────────────────────────────────────────────────────
  -- Both vim.schedule calls fire after window.open() returns and controller
  -- is assigned in picker.lua, solving the nil-controller timing issue.
  vim.schedule(function()
    if closed then return end
    if vim.api.nvim_win_is_valid(prompt_win) then
      vim.api.nvim_set_current_win(prompt_win)
      vim.cmd("startinsert!")
    end
  end)

  vim.schedule(function()
    if closed then return end
    if callbacks.on_prompt_change then
      pcall(callbacks.on_prompt_change, get_prompt())
    end
  end)

  -- ── controller ────────────────────────────────────────────────────────────
  controller = {
    update       = update,
    get_prompt   = get_prompt,
    close        = close,
    show_preview = show_preview,
    hide_preview = hide_preview,
    results_win  = list_win,   -- alias kept for on_preview callback compatibility
  }

  return controller
end

return M
