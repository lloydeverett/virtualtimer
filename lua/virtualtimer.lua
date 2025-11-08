
-- @timer(....10s)
-- @timer(....20s)
-- @timer(....20s)
-- @timer(1h2m30s)

local HL_CURRENT_TIMER = "VirtualTimerCurrentTimer"
local HL_SUBSEQUENT_TIMER = "VirtualTimerSubsequentTimer"
local HL_COMPLETED_TIMER = "VirtualTimerCompleted"

local function set_highlights()
    vim.cmd("hi link " .. HL_CURRENT_TIMER    .. " MiniHipatternsHack")
    vim.cmd("hi link " .. HL_SUBSEQUENT_TIMER .. " MiniHipatternsTodo")
    vim.cmd("hi link " .. HL_COMPLETED_TIMER  .. " MiniHipatternsNote")
end

local function get_command_range(opts)
    if opts.range ~= 0 then
        return opts.line1 - 1, opts.line2
    else
        return 0, -1
    end
end

local function get_namespace()
    return vim.api.nvim_create_namespace("virtualtimer")
end

local function make_extmark_opts(opts)
    local result = {}
    -- result.virt_text_win_col = 80
    for k, v in pairs(opts) do
        result[k] = v
    end
    return result
end

local function parse_duration(str)
    local hours, minutes, seconds = 0, 0, 0

    local h_match = string.match(str, "(%d+)h")
    if h_match then
        hours = tonumber(h_match) or 0
    end

    local m_match = string.match(str, "(%d+)m")
    if m_match then
        minutes = tonumber(m_match) or 0
    end

    local s_match = string.match(str, "(%d+)s")
    if s_match then
        seconds = tonumber(s_match) or 0
    else
        s_match = string.match(str, "(%d+)$")
        if s_match then
            seconds = tonumber(s_match) or 0
        end
    end

    return (hours * 3600) + (minutes * 60) + seconds
end

local function parse_virt_text_duration(str)
    local h, m, s = string.match(str, "(%d+):(%d+):(%d+)")
    if h ~= nil and m ~= nil and s ~= nil then
        return (h * 3600) + (m * 60) + s
    end
    h = nil; m = nil; s = nil;
    m, s = string.match(str, "(%d+):(%d+)")
    if m ~= nil and s ~= nil then
        return (m * 60) + s
    end
    error("Could not parse virt text duration '" .. str .. "'")
end

local function format_seconds(seconds)
    local s = seconds % 60
    seconds = math.floor(seconds / 60)
    local m = seconds % 60
    seconds = math.floor(seconds / 60)
    local h = seconds
    if h == 0 then
        return string.format("%02d:%02d", m, s)
    else
        return string.format("%02d:%02d:%02d", h, m, s)
    end
end

local M = {}

function M.setup(_)

local augroup = vim.api.nvim_create_augroup("VirtualTimerHighlights", { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', {
    group = augroup,
    callback = set_highlights
})
set_highlights()

vim.api.nvim_create_user_command("VtClear", function(opts)
    local ns = get_namespace()
    local start_line, end_line = get_command_range(opts)

    vim.api.nvim_buf_clear_namespace(0, ns, start_line, end_line)
end, { range = true })

vim.api.nvim_create_user_command("VtParse", function(opts)
    local ns = get_namespace()
    local start_line, end_line = get_command_range(opts)

    vim.api.nvim_buf_clear_namespace(0, ns, start_line, end_line)

    local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)

    local match_index = 1
    for i, line in ipairs(lines) do
        local match = string.match(line, "@timer%(([0-9hms.]+)%)")
        local markdown_completed_pattern = "^%s*[-*]%s%[[Xx]%]"
        if match ~= nil and string.match(line, markdown_completed_pattern) == nil then
            match_index = match_index + 1
            local seconds = parse_duration(match)
            vim.api.nvim_buf_set_extmark(0, ns, start_line + i - 1, 0, make_extmark_opts({
                virt_text = { { "  " .. format_seconds(seconds) .. " ", HL_SUBSEQUENT_TIMER } }
            }))
        end
    end
end, { range = true })

if _G.virtualtimer == nil then
    _G.virtualtimer = {
        timer_id_for_buf = {},
    }
end

if _G.statusline_additions ~= nil then
    _G.statusline_additions.virtualtimer = function(_)
        local buf = vim.api.nvim_get_current_buf()
        if _G.virtualtimer.timer_id_for_buf[buf] ~= nil then
            return ""
        else
            return nil
        end
    end
end

local function cancel_timer(buf)
    if _G.virtualtimer.timer_id_for_buf[buf] ~= nil then
        vim.fn.timer_stop(_G.virtualtimer.timer_id_for_buf[buf])
        _G.virtualtimer.timer_id_for_buf[buf] = nil
    end
end

vim.api.nvim_create_user_command("VtStart", function(opts)
    local buf = vim.api.nvim_get_current_buf()
    local ns = get_namespace()
    local start_line, end_line = get_command_range(opts)

    cancel_timer(buf)

    local ok, extmarks = pcall(function()
        return vim.api.nvim_buf_get_extmarks(buf, ns, { start_line, 0 }, { end_line, -1 }, { details = true })
    end)
    if not ok or #extmarks == 0 then
        print("No timers found in range")
        return
    end

    local first_tick = true

    local function timer_tick()
        for _, extmark in ipairs(extmarks) do
            local id, _, _, details = table.unpack(extmark)
            local virt_text = details.virt_text
            if virt_text[1][2] == HL_CURRENT_TIMER or virt_text[1][2] == HL_SUBSEQUENT_TIMER then
                local row, col
                if not pcall(function()
                    local ret = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = false })
                    if ret == nil or #ret == 0 then error("failed to find extmark") end
                    row = ret[1]
                    col = ret[2]
                end) then
                    vim.notify("Failed to update timer in buffer; stopping")
                    cancel_timer(buf)
                    return
                end

                local hl = HL_CURRENT_TIMER
                local seconds = parse_virt_text_duration(virt_text[1][1])

                if first_tick then
                    if virt_text[1][2] == HL_SUBSEQUENT_TIMER then
                        vim.notify("Start timer with duration " .. format_seconds(seconds))
                    elseif virt_text[1][2] == HL_CURRENT_TIMER then
                        vim.notify("Resume timer with duration " .. format_seconds(seconds))
                    end
                    first_tick = false
                end

                seconds = seconds - 1
                if seconds == 0 then
                    vim.notify("Timer completed")
                    hl = HL_COMPLETED_TIMER
                end

                local new_virt_text = "  " .. format_seconds(seconds) .. " "
                vim.api.nvim_buf_set_extmark(buf, ns, row, col, make_extmark_opts({
                    id = id,
                    virt_text = { { new_virt_text, hl } }
                }))
                if not pcall(function()
                    vim.api.nvim_buf_set_extmark(buf, ns, row, col, make_extmark_opts({
                        id = id,
                        virt_text = { { new_virt_text, hl } }
                    }))
                end) then
                    vim.notify("Failed to update timer in buffer; stopping")
                    cancel_timer(buf)
                    return
                end

                details.virt_text = { { new_virt_text, hl } }
                return
            end
        end

        vim.notify("No timers left in buffer; stopping")
        cancel_timer(buf)
    end

    _G.virtualtimer.timer_id_for_buf[buf] = vim.fn.timer_start(1000, timer_tick, { ["repeat"] = -1 }) -- -1 means infinite repetition
end, { range = true })

vim.api.nvim_create_user_command("VtStop", function(_)
    local buf = vim.api.nvim_get_current_buf()

    if _G.virtualtimer.timer_id_for_buf[buf] == nil then
        print("No timers running in this buffer")
        return
    end

    cancel_timer(buf)

    vim.notify("Timer stopped")
end, {})

end

return M

