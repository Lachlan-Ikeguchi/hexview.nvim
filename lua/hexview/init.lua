-- ===========================================================
-- Plugin Hexadecimal Viewer and Editor (Batch Rendering)
-- Author: 	Damian V. Cechov
-- damianvcechov@gmail.com ©2026
-- ===========================================================

local M = {}
M.disabled_buffers = {}
local ns = vim.api.nvim_create_namespace("hexview_ns")
local cursor_ns = vim.api.nvim_create_namespace("hexview_cursor_ns")

-- ============================================================
-- CONFIGURATION
-- ============================================================
M.bytes_per_line = 52
M.auto_columns = true
M.ascii_start_col = 0
M.hex_width = 0

-- ============================================================
-- AUXILIARY FUNCTIONS
-- ============================================================
local function hex_width_for(cols)
	return cols * 3 + 2 * math.floor((cols - 1) / 4)
end

-- Total rendered line width for a given column count
local function line_width_for(cols)
	return 10 + hex_width_for(cols) + 3 + cols
end

function M.max_columns_for(width)
	local cols = math.floor((width - 13) / 4.5)
	if cols < 1 then
		return 1
	end
	while cols > 1 and line_width_for(cols) > width do
		cols = cols - 1
	end
	while line_width_for(cols + 1) <= width do
		cols = cols + 1
	end
	return cols
end

function M.setup_layout()
	M.hex_width = hex_width_for(M.bytes_per_line)
	M.ascii_start_col = 10 + M.hex_width + 3
end

function M.get_byte(idx)
	local edits = vim.b.hex_edits
	if edits and edits[tostring(idx)] then
		return edits[tostring(idx)]
	end

	if vim.b.hex_raw and idx <= (vim.b.hex_size or 0) then
		return string.byte(vim.b.hex_raw, idx)
	end
	return nil
end

-- ============================================================
-- 1. FETCH DATA
-- ============================================================
function M.load_binary()
	local filepath = vim.api.nvim_buf_get_name(0)
	local data = ""

	local f = io.open(filepath, "rb")
	if f then
		data = f:read("*all")
		f:close()
	else
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		data = table.concat(lines, "\n")
	end

	vim.b.hex_raw = data
	vim.b.hex_size = #data
	vim.b.hex_edits = {}
end

-- ============================================================
-- 2. GEN. TEXT
-- ============================================================

function M.generate_line_content(row)
	if not vim.b.hex_raw then
		return "", {}, {}
	end

	local base = (row - 1) * M.bytes_per_line

	-- Optimalizace
	local parts = {}

	-- Offset header
	table.insert(parts, string.format("%08X: ", base))

	local dirty_hex_ranges = {}
	local dirty_ascii_indices = {}

	local edits = vim.b.hex_edits or {}
	local current_hex_pos = 10

	-- HEX
	for i = 0, M.bytes_per_line - 1 do
		local idx = base + i + 1
		local b = M.get_byte(idx)

		if b then
			local val = tonumber(b)
			local hex = string.format("%02X", val or 0)

			if edits[tostring(idx)] ~= nil then
				table.insert(dirty_hex_ranges, { current_hex_pos, current_hex_pos + 2 })
				table.insert(dirty_ascii_indices, i)
			end

			if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
				table.insert(parts, hex .. " | ")
				current_hex_pos = current_hex_pos + 5
			else
				table.insert(parts, hex .. " ")
				current_hex_pos = current_hex_pos + 3
			end
		else
			-- Padding
			if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
				table.insert(parts, "   | ")
			else
				table.insert(parts, "   ")
			end
		end
	end

	-- SEPARATOR
	table.insert(parts, " | ")

	-- ASCII
	for i = 0, M.bytes_per_line - 1 do
		local idx = base + i + 1
		local b = M.get_byte(idx)
		if b then
			local val = tonumber(b)
			local c = (val and val >= 32 and val <= 126) and string.char(val) or "."
			table.insert(parts, c)
		else
			table.insert(parts, " ")
		end
	end

	return table.concat(parts), dirty_hex_ranges, dirty_ascii_indices
end

function M.redraw_line(row)
	local text, dirty_hex, dirty_ascii = M.generate_line_content(row)

	vim.opt_local.modifiable = true
	vim.api.nvim_buf_set_lines(0, row - 1, row, false, { text })

	vim.api.nvim_buf_clear_namespace(0, ns, row - 1, row)

	local len = #text
	for _, range in ipairs(dirty_hex) do
		if range[2] <= len then
			vim.api.nvim_buf_set_extmark(0, ns, row - 1, range[1], {
				end_col = range[2],
				hl_group = "HexViewChanged",
				priority = 101,
			})
		end
	end

	local hex_end_col = 10 + M.hex_width
	local ascii_start = hex_end_col + 3

	for _, offset_i in ipairs(dirty_ascii) do
		local col = ascii_start + offset_i
		if col < len then
			vim.api.nvim_buf_set_extmark(0, ns, row - 1, col, {
				end_col = col + 1,
				hl_group = "HexViewChanged",
				priority = 101,
			})
		end
	end

	vim.opt_local.modifiable = false
end

-- ============================================================
-- 3. CURSOR AND HIGHLIGHTS
-- ============================================================
function M.cursor_byte()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()
	local header_end = line:find(": ")
	if not header_end then
		return nil
	end

	local base = tonumber(line:sub(1, header_end - 1), 16)
	if not base then
		return nil
	end

	if col >= M.ascii_start_col then
		local ascii_offset = col - M.ascii_start_col
		if ascii_offset >= 0 and ascii_offset < M.bytes_per_line then
			return base + ascii_offset, 0, true
		end
		return nil
	end

	local char_at_cursor = line:sub(col + 1, col + 1)
	if not char_at_cursor:match("[%x]") then
		return nil
	end

	local start_idx = header_end + 2
	local byte_count = -0.5
	for i = start_idx, col + 1 do
		if line:sub(i, i):match("[%x]") then
			byte_count = byte_count + 0.5
		end
	end

	if byte_count < 0 then
		return nil
	end
	local nibble = (byte_count % 1 ~= 0) and 1 or 0
	return base + math.floor(byte_count), nibble, false
end

function M.highlight_cursor()
	vim.api.nvim_buf_clear_namespace(0, cursor_ns, 0, -1)
	local offset, _, _ = M.cursor_byte()
	if not offset then
		return
	end

	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line_idx = row - 1
	local byte_in_line = offset % M.bytes_per_line

	local hex_col = 10
	for i = 0, byte_in_line - 1 do
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			hex_col = hex_col + 5
		else
			hex_col = hex_col + 3
		end
	end

	local ascii_col = M.ascii_start_col + byte_in_line

	vim.api.nvim_buf_set_extmark(0, cursor_ns, line_idx, hex_col, {
		end_col = hex_col + 2,
		hl_group = "HexViewCursor",
		priority = 200,
	})
	vim.api.nvim_buf_set_extmark(0, cursor_ns, line_idx, ascii_col, {
		end_col = ascii_col + 1,
		hl_group = "HexViewCursor",
		priority = 200,
	})
end

-- ============================================================
-- 4. EDITATION (r, R)
-- ============================================================

local function write_byte(offset, byte_val)
	if not byte_val then
		return false
	end
	local edits = vim.b.hex_edits or {}
	edits[tostring(offset + 1)] = tonumber(byte_val)
	vim.b.hex_edits = edits
	return true
end

local function write_nibble(offset, nibble_idx, char)
	local val = tonumber(char, 16)
	if not val then
		return false
	end

	local raw_val = M.get_byte(offset + 1)
	if not raw_val then
		return false
	end

	local data = tonumber(raw_val)
	if not data then
		return false
	end

	local bit = require("bit")
	local new_data = data

	if nibble_idx == 0 then
		new_data = bit.bor(bit.band(data, 0x0F), bit.lshift(val, 4))
	else
		new_data = bit.bor(bit.band(data, 0xF0), val)
	end

	return write_byte(offset, new_data)
end

function M.replace_one()
	local offset, nibble, is_ascii = M.cursor_byte()
	if not offset then
		return
	end

	local char_code = vim.fn.getchar()
	if char_code == 27 then
		return
	end

	local char = (type(char_code) == "number") and vim.fn.nr2char(char_code) or char_code
	local changed = false

	if is_ascii then
		local byte_val = string.byte(char)
		changed = write_byte(offset, byte_val)
	else
		if char:match("[%x]") then
			changed = write_nibble(offset, nibble, char)
		end
	end

	if changed then
		M.redraw_line(vim.api.nvim_win_get_cursor(0)[1])
		vim.opt_local.modified = true
	end
end

function M.replace_continuous()
	vim.b.hex_replace_active = true
	vim.cmd("redrawstatus")

	while true do
		M.highlight_cursor()
		vim.cmd("redraw")

		local ok, char_code = pcall(vim.fn.getchar)
		if not ok or char_code == 27 then
			break
		end

		local char = (type(char_code) == "number") and vim.fn.nr2char(char_code) or char_code
		local offset, nibble, is_ascii = M.cursor_byte()

		if not offset then
			break
		end
		local changed = false

		if is_ascii then
			local byte_val = string.byte(char)
			if byte_val and byte_val >= 32 and byte_val <= 255 then
				changed = write_byte(offset, byte_val)
			end
		else
			if char:match("[%x]") then
				changed = write_nibble(offset, nibble, char)
			end
		end

		if changed then
			M.redraw_line(vim.api.nvim_win_get_cursor(0)[1])
			vim.opt_local.modified = true
			M.smart_move("l")
		end
	end

	vim.b.hex_replace_active = false
	vim.cmd("redrawstatus")
	print(" ")
end

-- ============================================================
-- 5. MOVEMENT
-- ============================================================
function M.smart_move(key)
	local cmd = (key == "l" or key == "<Right>") and "l" or "h"
	local is_left = (cmd == "h")
	local cur_row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	local hex_start = 10
	local hex_end = 10 + M.hex_width - 1
	local ascii_start = M.ascii_start_col

	vim.cmd("normal! " .. cmd)
	local cur_col = vim.api.nvim_win_get_cursor(0)[2]

	if not is_left and cur_col > hex_end and cur_col < ascii_start then
		vim.api.nvim_win_set_cursor(0, { cur_row, ascii_start })
		return
	end

	if is_left and cur_col < ascii_start and cur_col > hex_end then
		local target = hex_end
		while target > hex_start do
			if line:sub(target + 1, target + 1):match("[%x]") then
				break
			end
			target = target - 1
		end
		vim.api.nvim_win_set_cursor(0, { cur_row, target })
		return
	end

	if cur_col >= hex_start and cur_col <= hex_end then
		local safeguard = 0
		while line:sub(cur_col + 1, cur_col + 1):match("[ |]") and safeguard < 5 do
			vim.cmd("normal! " .. cmd)
			cur_col = vim.api.nvim_win_get_cursor(0)[2]
			safeguard = safeguard + 1
		end
	end

	if cur_col < hex_start then
		vim.api.nvim_win_set_cursor(0, { cur_row, hex_start })
	end
end

-- ============================================================
-- 5.5 FIND
-- ============================================================

function M.goto_byte_offset(offset)
	if offset > (vim.b.hex_size or 0) then
		return
	end

	local row = math.ceil(offset / M.bytes_per_line)

	local byte_in_line = (offset - 1) % M.bytes_per_line -- 0-based index v řádku
	local col = 10

	for i = 0, byte_in_line - 1 do
		col = col + 2
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			col = col + 3 -- " | " separator
		else
			col = col + 1 -- " " space
		end
	end

	vim.api.nvim_win_set_cursor(0, { row, col })
	vim.cmd("normal! zz")
	M.highlight_cursor()
end

function M.get_current_binary_string()
	local size = vim.b.hex_size or 0
	local edits = vim.b.hex_edits or {}

	if next(edits) == nil then
		return vim.b.hex_raw
	end

	local t = {}
	for i = 1, size do
		local b_val = M.get_byte(i)
		table.insert(t, string.char(b_val))
	end
	return table.concat(t)
end

function M.find_hex_dialog()
	vim.ui.input({ prompt = "Find HEX (e.g. AA BB 01): " }, function(input)
		if not input or input == "" then
			return
		end

		local clean_hex = input:gsub("[%s|]", "")

		if #clean_hex % 2 ~= 0 then
			print("HexView Error: Enter whole bytes")
			return
		end

		local search_bytes = ""
		for i = 1, #clean_hex, 2 do
			local byte_str = clean_hex:sub(i, i + 1)
			local byte_val = tonumber(byte_str, 16)
			if not byte_val then
				print("HexView Error: Invalid HEX characters.")
				return
			end
			search_bytes = search_bytes .. string.char(byte_val)
		end

		vim.b.last_search_bytes = search_bytes

		M.find_next()
	end)
end

function M.find_next()
	local pattern = vim.b.last_search_bytes
	if not pattern then
		print("HexView: No previous search pattern.")
		return
	end

	local current_offset, _, _ = M.cursor_byte()
	current_offset = current_offset or 1

	local data = M.get_current_binary_string()

	-- string.find(string, pattern, init_pos, plain_search)
	local start_pos, end_pos = string.find(data, pattern, current_offset + 1, true)

	if not start_pos then
		-- Wrap around
		print("HexView: The search has come to an end. Resuming from the beginning...")
		start_pos, end_pos = string.find(data, pattern, 1, true)
	end

	if start_pos then
		M.goto_byte_offset(start_pos)
		local len = end_pos - start_pos + 1
		print(string.format("Found on offset 0x%X (length %d)", start_pos, len))
	else
		print("HexView: None found.")
	end
end

-- ============================================================
-- 6. UI & STATUSLINE
-- ============================================================
function M.setup_keymaps()
	local moves = { "h", "l", "<Left>", "<Right>" }
	for _, k in ipairs(moves) do
		vim.keymap.set("n", k, function()
			M.smart_move(k)
		end, { buffer = true, silent = true })
	end
	vim.keymap.set("n", "r", function()
		M.replace_one()
	end, { buffer = true, silent = true })
	vim.keymap.set("n", "R", function()
		M.replace_continuous()
	end, { buffer = true, silent = true })

	vim.keymap.set("n", "/", function()
		M.find_hex_dialog()
	end, { buffer = true, silent = false, desc = "Find HEX" })
	vim.keymap.set("n", "n", function()
		M.find_next()
	end, { buffer = true, silent = false, desc = "Find Next HEX" })

	vim.api.nvim_buf_create_user_command(0, "HexSet", function(opts)
		local val = tonumber(opts.args)
		if val and val > 0 then
			require("hexview").set_columns(val)
		else
			print("HexView: Enter a valid number of columns (e.g. :HexSet 16)")
		end
	end, { nargs = 1 })
end

function M.cursor_offset_label()
	local offset, nibble, is_ascii = M.cursor_byte()
	if not offset then
		return ""
	end
	local loc = is_ascii and "[ASCII]" or "[HEX]"
	return string.format("%s 0x%08X", loc, offset)
end

function M.get_statusline_content()
	local mode_info = ""
	if vim.b.hex_replace_active then
		mode_info = "%#HexViewModeEdit# -- REPLACE -- %*"
	end
	return string.format("  %%f %%m %%= %s Col: %d  %%l,%%c  %%P ", mode_info, M.bytes_per_line)
end

function M.setup_ui()
	vim.api.nvim_set_hl(0, "HexViewOffset", { fg = "#FF9E64", bold = true })
	vim.api.nvim_set_hl(0, "HexViewHeader", { fg = "#FF9E64", bold = true })
	vim.api.nvim_set_hl(0, "HexViewChanged", { fg = "#FF007C", bold = true })
	vim.api.nvim_set_hl(0, "HexViewCursor", { bg = "#330000", fg = "#FFFF00", bold = true })
	vim.api.nvim_set_hl(0, "HexViewModeEdit", { fg = "#00FF00", bg = "#003300", bold = true })

	-- !!! ZRYCHLENÍ: Použití Regex Syntax místo Extmarks pro offsety !!!
	vim.cmd([[syntax match HexViewOffset /^[0-9A-F]\{8\}:/]])

	local O, N = "%#HexViewHeader#", "%*"
	local hex_header_parts = {}
	for i = 0, M.bytes_per_line - 1 do
		local hex = string.format("%02X", i)
		if (i + 1) % 4 == 0 and (i + 1) < M.bytes_per_line then
			table.insert(hex_header_parts, hex .. " | ")
		else
			table.insert(hex_header_parts, hex .. " ")
		end
	end
	local hex_header_str = table.concat(hex_header_parts)
	local ascii_header = " | " .. O .. "ASCII" .. N
	local header = " Offset   " .. O .. hex_header_str .. N .. ascii_header

	vim.opt_local.winbar = header .. "%=" .. "%#HexViewHeader# %{v:lua.require'hexview'.cursor_offset_label()} "
	vim.opt_local.statusline = "%!v:lua.require'hexview'.get_statusline_content()"
end

-- ============================================================
-- 7. ENABLE / DISABLE / REFRESH (OPTIMIZED)
-- ============================================================

local function apply_columns(cols)
	local current_offset = M.cursor_byte() or 0
	M.bytes_per_line = cols
	M.refresh_view()
	if current_offset > 0 then
		local new_row = math.floor((current_offset - 1) / M.bytes_per_line) + 1
		pcall(vim.api.nvim_win_set_cursor, 0, { new_row, 10 })
	end
end

function M.set_columns(cols)
	if cols < 1 then
		return
	end
	M.auto_columns = false
	apply_columns(cols)
	print("HexView: Set on " .. cols .. " columns.")
end

function M.adapt_columns()
	if not M.auto_columns then
		return
	end
	local ok, width = pcall(vim.api.nvim_win_get_width, 0)
	if not ok or width <= 0 then
		return
	end
	local cols = M.max_columns_for(width)
	if cols ~= M.bytes_per_line then
		apply_columns(cols)
	end
end

function M.refresh_view()
	M.setup_layout()
	M.setup_ui()

	vim.opt_local.modifiable = true
	local size = vim.b.hex_size or 0
	local total_lines = math.ceil(size / M.bytes_per_line)
	if total_lines == 0 then
		total_lines = 1
	end

	local all_lines = {}
	for row = 1, total_lines do
		local text = M.generate_line_content(row)
		table.insert(all_lines, text)
	end

	vim.api.nvim_buf_set_lines(0, 0, -1, false, all_lines)

	local edits = vim.b.hex_edits
	if edits and next(edits) then
	end

	vim.opt_local.modifiable = false
end

function M.enable()
	M.disabled_buffers[vim.api.nvim_get_current_buf()] = nil
	M.load_binary()
	if not vim.b.hex_raw then
		vim.b.hex_raw = ""
		vim.b.hex_size = 0
	end
	if not vim.b.hex_edits then
		vim.b.hex_edits = {}
	end
	vim.b.hex_replace_active = false

	vim.opt_local.modifiable = true
	vim.opt_local.readonly = false
	vim.opt_local.number = false
	vim.opt_local.relativenumber = false
	vim.opt_local.wrap = false
	vim.bo.filetype = "hexview"

	if M.auto_columns then
		local ok, width = pcall(vim.api.nvim_win_get_width, 0)
		if ok and width > 0 then
			M.bytes_per_line = M.max_columns_for(width)
		end
	end
	M.refresh_view()
	vim.api.nvim_win_set_cursor(0, { 1, 10 })
	vim.b.did_ftplugin = 1
	M.setup_keymaps()

	local au_group = vim.api.nvim_create_augroup("HexViewCursor", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = au_group,
		buffer = 0,
		callback = M.highlight_cursor,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = au_group,
		buffer = 0,
		callback = function()
			M.adapt_columns()
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = au_group,
		callback = function()
			if vim.bo.filetype == "hexview" then
				M.adapt_columns()
			end
		end,
	})
	M.highlight_cursor()

	vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = 0, callback = M.save })
end

function M.disable()
	M.save()
	local buf = vim.api.nvim_get_current_buf()
	M.disabled_buffers[buf] = true

	vim.api.nvim_clear_autocmds({ group = "HexViewCursor" })
	vim.api.nvim_buf_clear_namespace(0, cursor_ns, 0, -1)
	vim.api.nvim_clear_autocmds({ event = "BufWriteCmd", buffer = 0 })
	pcall(vim.api.nvim_buf_del_user_command, 0, "HexSet")
	vim.opt_local.winbar = nil
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
	vim.cmd("edit!")
	vim.opt_local.binary = true
	vim.opt_local.fixeol = false
	vim.opt_local.eol = false
	vim.opt_local.readonly = true
	vim.opt_local.modifiable = false
	vim.opt_local.statusline = ""
	vim.opt_local.syntax = "off"
	vim.bo.filetype = ""
	vim.b.hex_raw = nil
	vim.b.hex_edits = nil
	vim.b.hex_size = nil
	vim.b.hex_replace_active = nil
	print("HexView: RAW mode.")
end

function M.save()
	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		print("Error: Buffer has no name.")
		return
	end
	local f = assert(io.open(name, "wb"))

	local size = vim.b.hex_size or 0
	local chunk_size = 1024 * 64
	local buffer = {}

	for i = 1, size do
		local b = M.get_byte(i)
		local val = tonumber(b) or 0
		table.insert(buffer, string.char(val))

		if #buffer >= chunk_size then
			f:write(table.concat(buffer))
			buffer = {}
		end
	end

	if #buffer > 0 then
		f:write(table.concat(buffer))
	end
	f:close()

	M.load_binary()
	M.refresh_view()
	vim.opt_local.modified = false
	print("Writed")
end

-- ============================================================
-- 8. SETUP
-- ============================================================
function M.setup(config)
	config = config or {}
	if config.auto_columns ~= nil then
		M.auto_columns = config.auto_columns
	end
	if config.bytes_per_line then
		M.bytes_per_line = config.bytes_per_line
		M.auto_columns = false
	end
	M.setup_layout()
	local group = vim.api.nvim_create_augroup("HexViewAutoDetect", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "*",
		callback = function(ev)
			if require("hexview").disabled_buffers[ev.buf] then
				return
			end
			local file = ev.file
			if not file or file == "" then
				return
			end
			if vim.bo[ev.buf].binary then
				vim.schedule(function()
					if vim.bo[ev.buf].filetype ~= "hexview" then
						require("hexview").enable()
					end
				end)
				return
			end
			local f = io.open(file, "rb")
			if not f then
				return
			end
			local chunk = f:read(1024)
			f:close()
			if chunk and chunk:find("%z") then
				vim.schedule(function()
					if vim.bo[ev.buf].filetype ~= "hexview" then
						require("hexview").enable()
					end
				end)
			end
		end,
	})
end

return M
