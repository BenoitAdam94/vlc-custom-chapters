-- ============================================================
--  chapter_loader.lua  –  VLC Lua Extension
--  Custom Chapters v1.4
--
--  Chapter file format (same name as video, .txt extension):
--    00:00:00 - Chapter 1
--    00:50:00 - Chapter 2
--    01:03:50 - Other chapter name
--
--  Install:
--    Linux   : ~/.local/share/vlc/lua/extensions/
--    macOS   : ~/Library/Application Support/org.videolan.vlc/lua/extensions/
--    Windows : %APPDATA%\vlc\lua\extensions\
--  Activate once via View -> Custom Chapters, then it's automatic.
-- ============================================================

function descriptor()
    return {
        title        = "Custom Chapters",
        version      = "1.4",
        author       = "Custom",
        shortdesc    = "Load custom chapters from .txt file",
        description  = "Reads HH:MM:SS chapters from a .txt file next to the video.\n"
                    .. "Format:  00:00:00 - Chapter name",
        capabilities = { "input-listener" }
    }
end

-- ── Helpers ────────────────────────────────────────────────

local function parse_time(ts)
    ts = ts:match("^%s*(.-)%s*$")
    local h, m, s = ts:match("^(%d+):(%d%d):(%d%d)$")
    if h and m and s then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    return nil
end

local function uri_to_path(uri)
    if not uri then return nil end
    local path = uri:gsub("^file://", "")
    path = path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    if path:match("^/[A-Za-z]:/") then
        path = path:sub(2)
    end
    return path
end

local function find_chapter_file(video_path)
    if not video_path then return nil end
    local base = video_path:match("^(.+)%.[^%.]+$") or video_path
    local candidate = base .. ".txt"
    local f = io.open(candidate, "r")
    if f then f:close(); return candidate end
    return nil
end

local function parse_chapter_file(path)
    local chapters = {}
    local f = io.open(path, "r")
    if not f then return chapters end
    for line in f:lines() do
        local ts, title = line:match("^(%d+:%d%d:%d%d)%s*[%-–]+%s*(.+)$")
        if ts and title then
            local secs = parse_time(ts)
            if secs then
                title = title:match("^(.-)%s*$")
                chapters[#chapters + 1] = { time = secs, name = title }
            end
        end
    end
    f:close()
    table.sort(chapters, function(a, b) return a.time < b.time end)
    return chapters
end

-- ── State ──────────────────────────────────────────────────

local dlg        = nil
local status_lbl = nil

-- ── Safe dialog helpers ────────────────────────────────────

local function safe_delete_dialog()
    if dlg then
        pcall(function() dlg:delete() end)
        dlg = nil
        status_lbl = nil
    end
end

local function build_waiting_dialog()
    safe_delete_dialog()
    local ok, d = pcall(vlc.dialog, "Custom Chapters")
    if not ok or not d then return end
    dlg = d
    local ok2, lbl = pcall(function()
        return dlg:add_label("Waiting for video...", 1, 1, 2, 1)
    end)
    if ok2 then status_lbl = lbl end
    pcall(function() dlg:add_button("Reload", trigger_reload, 1, 2, 1, 1) end)
    pcall(function() dlg:add_button("Close",  deactivate,     2, 2, 1, 1) end)
    pcall(function() dlg:show() end)
end

local function build_chapter_dialog(chapters)
    safe_delete_dialog()
    local ok, d = pcall(vlc.dialog, "Custom Chapters")
    if not ok or not d then return end
    dlg = d

    pcall(function()
        dlg:add_label(
            string.format("%d custom chapter(s) — click to jump:", #chapters),
            1, 1, 2, 1)
    end)

    for i, ch in ipairs(chapters) do
        local hh = math.floor(ch.time / 3600)
        local mm = math.floor((ch.time % 3600) / 60)
        local ss = ch.time % 60
        local label = string.format("%d:%02d:%02d  %s", hh, mm, ss, ch.name)
        local seek_time = ch.time
        pcall(function()
            dlg:add_button(label, function()
                pcall(function()
                    local inp = vlc.object.input()
                    if inp then
                        vlc.var.set(inp, "time", seek_time * 1000000)
                    end
                end)
            end, 1, i + 1, 2, 1)
        end)
    end

    local row = #chapters + 2
    pcall(function() dlg:add_button("Reload", trigger_reload, 1, row, 1, 1) end)
    pcall(function() dlg:add_button("Close",  deactivate,     2, row, 1, 1) end)
    pcall(function() dlg:show() end)
end

-- ── Extension lifecycle ────────────────────────────────────

function activate()
    build_waiting_dialog()
    -- small delay: VLC may not have input ready yet on fresh open
    vlc.misc.mwait(vlc.misc.mdate() + 500000)
    load_chapters()
end

function deactivate()
    safe_delete_dialog()
end

function close()
    deactivate()
end

function input_changed()
    -- Use pcall: input_changed can fire at unstable moments
    pcall(function()
        local item = vlc.input.item()
        if not item then
            -- no video playing: show waiting dialog
            if dlg then build_waiting_dialog() end
            return
        end

        local vid_path  = uri_to_path(item:uri())
        local chap_path = find_chapter_file(vid_path)

        if chap_path then
            -- ensure dialog exists (e.g. was closed)
            if not dlg then build_waiting_dialog() end
            load_chapters()
        else
            -- no chapter file: just show waiting state, don't close
            if dlg then
                pcall(function()
                    if status_lbl then
                        status_lbl:set_text("No .txt found for this video.")
                    end
                end)
            end
        end
    end)
end

function trigger_reload()
    load_chapters()
end

-- ── Core logic ─────────────────────────────────────────────

function load_chapters()
    pcall(function()
        local item = vlc.input.item()
        if not item then
            set_status("No media item.")
            return
        end

        local vid_path  = uri_to_path(item:uri())
        local chap_path = find_chapter_file(vid_path)

        if not chap_path then
            set_status("No .txt found for:\n" .. (vid_path or "?"))
            return
        end

        local chapters = parse_chapter_file(chap_path)
        if #chapters == 0 then
            set_status("No valid HH:MM:SS entries in:\n" .. chap_path)
            return
        end

        build_chapter_dialog(chapters)
    end)
end

function set_status(msg)
    pcall(function()
        if status_lbl then
            status_lbl:set_text(msg)
        end
    end)
    pcall(function()
        vlc.msg.info("[CustomChapters] " .. tostring(msg))
    end)
end
