--[[
    widget.lua
    conky-system, all-Lua/Cairo rebuild of the original TEXT-based
    conky-system.conf, in a single file.

    Follows the conky-widget-builder skill conventions:
    - no global leakage (everything local, state in W / CFG)
    - no blocking I/O in conky_main: all shell-outs (lsb_release, cpuinfo,
      sensors, checkupdates/apt-check) go through the generic cached()
      helper, wrapped in pcall, on a per-source refresh interval
    - portable drawing surface: conky_surface() preferred, cairo_xlib
      fallback for builds without it
    - avoids Lua 5.3+-only bitwise operators (>>, &) in hex_to_rgb, since
      some Conky packages still ship an older Lua 5.1 build
    - single file by design (explicit user preference: fewest files
      possible) -- helpers are kept generic/reused rather than duplicated
      per section
--]]

require("cairo")

-- Portable drawing-surface helper: prefer conky_surface() (X11 + Wayland),
-- fall back to cairo_xlib_surface_create for builds without it.
local has_cairo_xlib, cairo_xlib = pcall(require, "cairo_xlib")
if not has_cairo_xlib then
    cairo_xlib = setmetatable({}, {
        __index = function(_, k) return _G[k] end,
    })
end

local function get_draw_surface()
    if conky_surface then
        local s = conky_surface()
        if s then return s, false end
    end
    if conky_window and cairo_xlib_surface_create then
        local s = cairo_xlib_surface_create(conky_window.display,
            conky_window.drawable, conky_window.visual,
            conky_window.width, conky_window.height)
        return s, true
    end
    return nil, false
end

-- ==================== config ====================

local CFG = {
    network_iface = "enp0s31f6", -- change to your primary network interface
    font = "DejaVu Sans Mono",
    margin = 14,       -- outer margin, left/right
    top_margin = 14,
    pad = 10,          -- inner padding per box
    gap = 10,          -- vertical gap between boxes
    corner_radius = 10,
    graph_points = 40, -- rolling history length for graphs

    -- AUR helper for extra "Updates" line, in addition to the pacman/apt
    -- check below. Set to "yay", "paru", or "" to disable AUR checking.
    aur_helper = "yay",

    -- Layer 1 is the base glass fill behind every box -- the one layer
    -- worth tuning per-wallpaper, since a busier/brighter background
    -- often wants a darker or more opaque base to keep text readable.
    glass_base_color = 0x08081A,
    glass_base_alpha = 0.35,

    colors = {
        text     = 0xE8E8E8, -- light gray
        accent1  = 0xE7660B, -- orange
        accent2  = 0xDCE142, -- yellow
        accent3  = 0x42E147, -- green
        accent4  = 0x0055FF, -- blue
        accent5  = 0xFFFFFF, -- white
        danger   = 0xFF3B30, -- red, used above 90% load/usage
    },
}

-- ==================== widget state ====================

local W = {
    cache = {},     -- generic cache store, keyed by cached() calls below
    cpu_hist = {},
    up_hist = {},
    down_hist = {},
}

-- ==================== generic helpers ====================

-- Division-based hex->rgb (no bitwise ops, works on Lua 5.1 and 5.3+)
local function hex_to_rgb(hex)
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    return r / 255, g / 255, b / 255
end

local function hex_to_rgba(hex, alpha)
    local r, g, b = hex_to_rgb(hex)
    return r, g, b, alpha
end

-- Blend a hex color toward white by `amt` (0..1) -- used for brighter
-- borders/highlights on top of a base fill color.
local function lighten(hex, amt)
    local r, g, b = hex_to_rgb(hex)
    r = r + (1 - r) * amt
    g = g + (1 - g) * amt
    b = b + (1 - b) * amt
    return r, g, b
end

-- Shared green->yellow->red mapping for load/usage percentages (0..100),
-- reused by both the block bars and the CPU graph so the whole widget
-- speaks one consistent "VU meter" color language, matching the
-- green/yellow/red gradient used throughout conky-system-lua-V4's bars.
local function load_color_hex(pct)
    if pct < 70 then return CFG.colors.accent3      -- green
    elseif pct < 90 then return CFG.colors.accent2  -- yellow
    else return CFG.colors.danger end                -- red
end

local function shell(cmd)
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a")
    h:close()
    if out then out = out:gsub("%s+$", "") end
    return out
end

-- Generic cache: call fn() at most once per `interval` seconds, per key.
-- Always wrapped in pcall so a failing command never kills conky_main().
local function cached(key, interval, fn)
    local c = W.cache[key]
    if not c then
        c = { value = nil, last = 0 }
        W.cache[key] = c
    end
    local now = os.time()
    if now - c.last >= interval then
        local ok, result = pcall(fn)
        if ok and result ~= nil then
            c.value = result
        end
        c.last = now
    end
    return c.value
end

local function push_value(buffer, maxlen, value)
    table.insert(buffer, value)
    if #buffer > maxlen then table.remove(buffer, 1) end
end

-- ==================== cached data sources ====================

local function get_distro()
    return cached("distro", 86400, function()
        return shell("lsb_release -d | cut -f2") or "Linux"
    end) or "Linux"
end

local function get_cpu_model()
    return cached("cpu_model", 86400, function()
        local s = shell("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/ @.*//'")
        return s and s:match("^%s*(.-)%s*$") or "Unknown CPU"
    end) or "Unknown CPU"
end

local function get_cpu_temp()
    return cached("cpu_temp", 5, function()
        return shell("sensors 2>/dev/null | grep -i package | awk '{print $4}'")
    end)
end

-- Detect the system's package manager once (doesn't change at runtime).
-- More robust than checking for a single hardcoded binary path like
-- apt-check, which isn't guaranteed to be installed on every Debian/
-- Ubuntu/Mint system.
local function get_pkg_manager()
    return cached("pkg_manager", 86400, function()
        local p = shell("command -v pacman 2>/dev/null")
        if p and p ~= "" then return "pacman" end
        local a = shell("command -v apt 2>/dev/null")
        if a and a ~= "" then return "apt" end
        return "none"
    end) or "none"
end

-- Updates: pacman (checkupdates) on Arch, `apt list --upgradable` on
-- Debian/Ubuntu/Mint -- picked via get_pkg_manager() rather than probing
-- for one specific apt-check binary that may not be installed.
local function get_updates_lines()
    return cached("updates", 1800, function()
        local mgr = get_pkg_manager()
        if mgr == "pacman" then
            local n = shell("checkupdates 2>/dev/null | wc -l")
            return { (tonumber(n) or 0) .. " updates available (pacman)" }
        elseif mgr == "apt" then
            local n = shell("apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")
            return { (tonumber(n) or 0) .. " updates available (apt)" }
        end
        return { "No supported package manager found" }
    end) or {}
end

-- AUR only makes sense on an Arch/pacman system -- skip it entirely
-- elsewhere instead of silently printing "0 AUR updates" on Mint/Ubuntu.
local function get_aur_updates_line()
    if get_pkg_manager() ~= "pacman" then return nil end
    if CFG.aur_helper ~= "yay" and CFG.aur_helper ~= "paru" then
        return nil
    end
    return cached("updates_aur", 1800, function()
        local n = shell(CFG.aur_helper .. " -Qua 2>/dev/null | wc -l")
        return (tonumber(n) or 0) .. " AUR updates available (" .. CFG.aur_helper .. ")"
    end)
end

-- ==================== drawing primitives ====================

local function draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_move_to(cr, x + r, y)
    cairo_line_to(cr, x + w - r, y)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_line_to(cr, x + w, y + h - r)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_line_to(cr, x + r, y + h)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_line_to(cr, x, y + r)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

-- Multi-layer liquid-glass box, ported from background-layout.lua's
-- 5-layer structure (base, vertical top/bottom reflections, horizontal
-- left highlight, top specular gloss, subtle inner glow) + gradient
-- border. Layer 4 (specular) is scaled to each box's own height instead
-- of a fixed 120px, since our boxes are much shorter than V4's single
-- 650px panel.
local function draw_glass_box(cr, x, y, w, h)
    local r = CFG.corner_radius

    -- Layer 1: base glass body (configurable, see CFG.glass_base_color/alpha)
    cairo_set_source_rgba(cr, hex_to_rgba(CFG.glass_base_color, CFG.glass_base_alpha))
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_fill(cr)

    cairo_save(cr)
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_clip(cr)

    -- Layer 2: vertical gradient -- reflections top and bottom
    local g2 = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(g2, 0.00, hex_to_rgba(0xFFFFFF, 0.30))
    cairo_pattern_add_color_stop_rgba(g2, 0.06, hex_to_rgba(0xDDEEFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 0.15, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.45, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.55, hex_to_rgba(0x050510, 0.0))
    cairo_pattern_add_color_stop_rgba(g2, 0.85, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.94, hex_to_rgba(0xCCDDFF, 0.12))
    cairo_pattern_add_color_stop_rgba(g2, 1.00, hex_to_rgba(0xFFFFFF, 0.28))
    cairo_set_source(cr, g2)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g2)

    -- Layer 3: horizontal highlight, light from the left
    local g3 = cairo_pattern_create_linear(x, y, x + w, y)
    cairo_pattern_add_color_stop_rgba(g3, 0.00, hex_to_rgba(0xFFFFFF, 0.32))
    cairo_pattern_add_color_stop_rgba(g3, 0.08, hex_to_rgba(0xEEF4FF, 0.16))
    cairo_pattern_add_color_stop_rgba(g3, 0.20, hex_to_rgba(0xCCDDFF, 0.05))
    cairo_pattern_add_color_stop_rgba(g3, 0.50, hex_to_rgba(0x000000, 0.0))
    cairo_pattern_add_color_stop_rgba(g3, 0.80, hex_to_rgba(0x8899CC, 0.03))
    cairo_pattern_add_color_stop_rgba(g3, 0.92, hex_to_rgba(0xAABBEE, 0.08))
    cairo_pattern_add_color_stop_rgba(g3, 1.00, hex_to_rgba(0xFFFFFF, 0.18))
    cairo_set_source(cr, g3)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g3)

    -- Layer 4: specular top gloss, height proportional to this box
    local spec_h = math.min(h * 0.35, 55)
    local g4 = cairo_pattern_create_linear(x, y, x, y + spec_h)
    cairo_pattern_add_color_stop_rgba(g4, 0.00, hex_to_rgba(0xFFFFFF, 0.38))
    cairo_pattern_add_color_stop_rgba(g4, 0.25, hex_to_rgba(0xEEF4FF, 0.18))
    cairo_pattern_add_color_stop_rgba(g4, 0.60, hex_to_rgba(0xFFFFFF, 0.04))
    cairo_pattern_add_color_stop_rgba(g4, 1.00, hex_to_rgba(0xFFFFFF, 0.0))
    cairo_set_source(cr, g4)
    cairo_rectangle(cr, x, y, w, spec_h)
    cairo_fill(cr)
    cairo_pattern_destroy(g4)

    -- Layer 5: subtle inner blue glow, inset horizontally
    local inset = math.min(10, w * 0.1)
    local g5 = cairo_pattern_create_linear(x + inset, y, x + w - inset, y)
    cairo_pattern_add_color_stop_rgba(g5, 0.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_pattern_add_color_stop_rgba(g5, 0.30, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 0.50, hex_to_rgba(0x3344CC, 0.10))
    cairo_pattern_add_color_stop_rgba(g5, 0.70, hex_to_rgba(0x2233AA, 0.06))
    cairo_pattern_add_color_stop_rgba(g5, 1.00, hex_to_rgba(0x1122FF, 0.0))
    cairo_set_source(cr, g5)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g5)

    cairo_restore(cr) -- lift the clip before stroking the border

    -- Border: vertical white/blue gradient with sharp top & bottom edges
    local gb = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(gb, 0.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_pattern_add_color_stop_rgba(gb, 0.10, hex_to_rgba(0xFFFFFF, 0.90))
    cairo_pattern_add_color_stop_rgba(gb, 0.30, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.50, hex_to_rgba(0x8899EE, 0.25))
    cairo_pattern_add_color_stop_rgba(gb, 0.70, hex_to_rgba(0xAABBFF, 0.45))
    cairo_pattern_add_color_stop_rgba(gb, 0.90, hex_to_rgba(0xFFFFFF, 0.85))
    cairo_pattern_add_color_stop_rgba(gb, 1.00, hex_to_rgba(0xFFFFFF, 0.10))
    cairo_set_source(cr, gb)
    cairo_set_line_width(cr, 1.0)
    draw_rounded_rect_path(cr, x + 0.5, y + 0.5, w - 1, h - 1, r)
    cairo_stroke(cr)
    cairo_pattern_destroy(gb)
end

-- Segmented "LED block" bar, matching the green->yellow->red VU-meter
-- style used throughout conky-system-lua-V4's bars. Each block's color is
-- fixed by its position on the 0..100 scale; only how many blocks are lit
-- depends on the current value.
local function draw_bar(cr, x, y, w, h, pct)
    pct = math.max(0, math.min(100, pct))
    local blocks = 24
    local space = 2
    local bw = (w - (blocks - 1) * space) / blocks
    local lit_count = math.floor(blocks * pct / 100 + 0.5)
    local r = math.min(h, bw) / 3

    for i = 1, blocks do
        local block_pos_pct = (i - 1) / blocks * 100
        local bx = x + (i - 1) * (bw + space)
        if i <= lit_count then
            local col = load_color_hex(block_pos_pct)
            local grad = cairo_pattern_create_linear(bx, y, bx, y + h)
            local lr, lg, lb = lighten(col, 0.35)
            cairo_pattern_add_color_stop_rgba(grad, 0, lr, lg, lb, 0.95)
            cairo_pattern_add_color_stop_rgba(grad, 1, hex_to_rgba(col, 0.85))
            cairo_set_source(cr, grad)
            draw_rounded_rect_path(cr, bx, y, bw, h, r)
            cairo_fill(cr)
            cairo_pattern_destroy(grad)
        else
            cairo_set_source_rgba(cr, 1, 1, 1, 0.06)
            draw_rounded_rect_path(cr, bx, y, bw, h, r)
            cairo_fill(cr)
        end
    end
end

-- Area+line graph from a rolling value buffer. Fill is a top-to-bottom
-- gradient (like lua1-graphs.lua's bg_colour/fg_colour gradients) and the
-- stroke is a lightened version of the same base color, echoing that
-- project's separate fg_bd_colour border layer.
local function draw_area_graph(cr, x, y, w, h, buffer, maxval, color_hex)
    local n = #buffer
    if n < 2 then return end
    maxval = math.max(maxval, 1)
    local step = w / (CFG.graph_points - 1)

    cairo_save(cr)
    cairo_translate(cr, x, y + h)
    cairo_scale(cr, 1, -1)

    local grad = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(grad, 0, hex_to_rgba(color_hex, 0.55))
    cairo_pattern_add_color_stop_rgba(grad, 1, hex_to_rgba(color_hex, 0.04))
    cairo_set_source(cr, grad)
    cairo_move_to(cr, 0, 0)
    for i = 1, n do
        local v = math.min(buffer[i], maxval)
        cairo_line_to(cr, (i - 1) * step, (v / maxval) * h)
    end
    cairo_line_to(cr, (n - 1) * step, 0)
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_pattern_destroy(grad)

    local lr, lg, lb = lighten(color_hex, 0.4)
    cairo_set_source_rgba(cr, lr, lg, lb, 0.95)
    cairo_set_line_width(cr, 1.5)
    cairo_move_to(cr, 0, (math.min(buffer[1], maxval) / maxval) * h)
    for i = 2, n do
        local v = math.min(buffer[i], maxval)
        cairo_line_to(cr, (i - 1) * step, (v / maxval) * h)
    end
    cairo_stroke(cr)
    cairo_restore(cr)
end

local function draw_text(cr, x, y, text, size, color_hex, alpha, bold, align)
    cairo_select_font_face(cr, CFG.font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local rr, gg, bb = hex_to_rgb(color_hex)
    cairo_set_source_rgba(cr, rr, gg, bb, alpha or 1)

    local tx = x
    if align == "center" or align == "right" then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, text, ext)
        tx = (align == "center") and (x - ext.width / 2) or (x - ext.width)
    end
    cairo_move_to(cr, tx, y)
    cairo_show_text(cr, text)
end

-- ==================== section content ====================

local function draw_sysinfo(cr, x, y, w, h)
    local sysname = conky_parse("${sysname}")
    local kernel = conky_parse("${kernel}")
    local uptime = conky_parse("${uptime}")
    draw_text(cr, x + w / 2, y + 22, get_distro(), 18, CFG.colors.accent1, 1, true, "center")
    draw_text(cr, x, y + 42, sysname .. " " .. kernel, 11, CFG.colors.text, 0.9)
    draw_text(cr, x, y + 60, "Uptime: " .. uptime, 11, CFG.colors.text, 0.9)
    draw_text(cr, x, y + 78, get_cpu_model(), 10, CFG.colors.text, 0.7)
end

local function draw_cpu(cr, x, y, w, h)
    local cpu_pct = tonumber(conky_parse("${cpu cpu0}")) or 0
    local temp = get_cpu_temp()
    local label = temp and temp ~= "" and ("CPU  " .. temp) or "CPU"
    draw_text(cr, x, y + 12, label, 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x + w, y + 12, string.format("%.0f%%", cpu_pct), 12, CFG.colors.text, 1, true, "right")
    draw_bar(cr, x, y + 20, w, 10, cpu_pct)
    draw_area_graph(cr, x, y + 36, w, h - 36, W.cpu_hist, 100, load_color_hex(cpu_pct))
end

local function draw_mem(cr, x, y, w, h)
    local used = conky_parse("${mem}")
    local free = conky_parse("${memeasyfree}")
    local pct = tonumber(conky_parse("${memperc}")) or 0
    draw_text(cr, x, y + 12, "Memory", 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x, y + 30, "Used: " .. used, 10, CFG.colors.text, 0.9)
    draw_text(cr, x + w, y + 30, "Free: " .. free, 10, CFG.colors.text, 0.9, false, "right")
    draw_bar(cr, x, y + 38, w, 10, pct)
end

-- /home counts as "separate" only if it's a different filesystem than /
-- (compared by device id via stat, cached -- this never changes at runtime).
local function has_separate_home()
    local v = cached("separate_home", 86400, function()
        local root_id = shell("stat -c %d / 2>/dev/null")
        local home_id = shell("stat -c %d /home 2>/dev/null")
        return root_id ~= nil and root_id ~= "" and home_id ~= nil and home_id ~= "" and root_id ~= home_id
    end)
    if v == nil then return true end -- unknown yet: assume separate, don't hide data
    return v
end

local function draw_disks(cr, x, y, w, h)
    local function disk_row(label, path, yy)
        local used = conky_parse("${fs_used " .. path .. "}")
        local free = conky_parse("${fs_free " .. path .. "}")
        local pct = tonumber(conky_parse("${fs_used_perc " .. path .. "}")) or 0
        draw_text(cr, x, yy, label .. "  Used: " .. used .. "  Free: " .. free, 10, CFG.colors.text, 0.9)
        draw_bar(cr, x, yy + 6, w, 9, pct)
    end
    draw_text(cr, x, y + 10, "Disks", 12, CFG.colors.accent2, 1, true)
    disk_row(has_separate_home() and "Root" or "/", "/", y + 30)
    if has_separate_home() then
        disk_row("Home", "/home", y + 70)
    end
end

-- Box height now depends on whether /home is a separate partition.
local function disks_section_height()
    return has_separate_home() and 132 or 92
end

local function draw_network(cr, x, y, w, h)
    local up = conky_parse("${upspeed " .. CFG.network_iface .. "}")
    local down = conky_parse("${downspeed " .. CFG.network_iface .. "}")
    local totalup = conky_parse("${totalup " .. CFG.network_iface .. "}")
    local totaldown = conky_parse("${totaldown " .. CFG.network_iface .. "}")

    draw_text(cr, x, y + 10, "Network", 12, CFG.colors.accent2, 1, true)
    draw_text(cr, x, y + 28, "Up: " .. up, 10, CFG.colors.text, 0.9)
    draw_text(cr, x + w, y + 28, "Down: " .. down, 10, CFG.colors.text, 0.9, false, "right")

    local half = (w - 8) / 2
    local up_max, down_max = 1, 1
    for _, v in ipairs(W.up_hist) do up_max = math.max(up_max, v) end
    for _, v in ipairs(W.down_hist) do down_max = math.max(down_max, v) end
    draw_area_graph(cr, x, y + 36, half, 40, W.up_hist, up_max * 1.2, CFG.colors.accent4)
    draw_area_graph(cr, x + half + 8, y + 36, half, 40, W.down_hist, down_max * 1.2, CFG.colors.accent3)

    draw_text(cr, x, y + 94, "Total up: " .. totalup, 9, CFG.colors.text, 0.7)
    draw_text(cr, x + w, y + 94, "Total down: " .. totaldown, 9, CFG.colors.text, 0.7, false, "right")
end

local function draw_processes(cr, x, y, w, h)
    draw_text(cr, x, y + 10, "Processes", 12, CFG.colors.accent2, 1, true)
    for i = 1, 6 do
        local name = conky_parse("${top name " .. i .. "}")
        local cpu = tonumber(conky_parse("${top cpu " .. i .. "}")) or 0
        local yy = y + 10 + i * 18
        draw_text(cr, x, yy, name, 10, CFG.colors.text, 0.85)
        draw_text(cr, x + w - 4, yy, string.format("%5.2f%%", cpu), 10, CFG.colors.text, 0.85, false, "right")
    end
end

local function draw_updates(cr, x, y, w, h)
    draw_text(cr, x, y + 10, "Updates", 12, CFG.colors.accent2, 1, true)

    local lines = {}
    for _, l in ipairs(get_updates_lines()) do
        if l ~= "" then table.insert(lines, l) end
    end
    local aur_line = get_aur_updates_line()
    if aur_line then table.insert(lines, aur_line) end

    for i, l in ipairs(lines) do
        draw_text(cr, x, y + 14 + i * 16, l, 10, CFG.colors.text, 0.85)
    end
end

local function draw_datetime(cr, x, y, w, h)
    local date_str = conky_parse("${time %A, %d %B, %Y}")
    local time_str = conky_parse("${time %H:%M}")
    draw_text(cr, x + w / 2, y + 16, date_str, 11, CFG.colors.text, 0.9, false, "center")
    draw_text(cr, x + w / 2, y + 42, time_str, 20, CFG.colors.accent1, 1, true, "center")
end

-- ==================== layout ====================

local SECTIONS = {
    { height = 112, draw = draw_sysinfo },
    { height = 95,  draw = draw_cpu },
    { height = 70,  draw = draw_mem },
    { height = disks_section_height, draw = draw_disks },
    { height = 132, draw = draw_network },
    { height = 140, draw = draw_processes },
    { height = 80,  draw = draw_updates },
    { height = 72,  draw = draw_datetime },
}

local function sec_h(sec)
    return type(sec.height) == "function" and sec.height() or sec.height
end

local function update_history()
    local cpu = tonumber(conky_parse("${cpu cpu0}")) or 0
    push_value(W.cpu_hist, CFG.graph_points, cpu)

    local up = tonumber(conky_parse("${upspeedf " .. CFG.network_iface .. "}")) or 0
    push_value(W.up_hist, CFG.graph_points, up)

    local down = tonumber(conky_parse("${downspeedf " .. CFG.network_iface .. "}")) or 0
    push_value(W.down_hist, CFG.graph_points, down)
end

local function draw_all(cr, canvas_w)
    local x = CFG.margin
    local w = canvas_w - 2 * CFG.margin
    local y = CFG.top_margin

    for _, sec in ipairs(SECTIONS) do
        local h = sec_h(sec)
        draw_glass_box(cr, x, y, w, h)
        sec.draw(cr, x + CFG.pad, y + CFG.pad, w - 2 * CFG.pad, h - 2 * CFG.pad)
        y = y + h + CFG.gap
    end
end

-- ==================== Conky hooks ====================

function conky_main()
    update_history()

    local surface, owns_surface = get_draw_surface()
    if not surface then return end
    local cr = cairo_create(surface)

    draw_all(cr, conky_window and conky_window.width or 280)

    cairo_destroy(cr)
    if owns_surface then
        cairo_surface_destroy(surface)
    end
end