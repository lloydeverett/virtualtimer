
-- @timer(10s)
-- @timer(20s)
-- @timer(20s)
-- @timer(1h2m30s)

local HL_CURRENT_TIMER = "VirtualTimerCurrentTimer"
local HL_SUBSEQUENT_TIMER = "VirtualTimerSubsequentTimer"
local HL_COMPLETED_TIMER = "VirtualTimerCompleted"

local function set_highlights()
    vim.cmd("hi link " .. HL_CURRENT_TIMER .. " MiniHipatternsHack")
    vim.cmd("hi link " .. HL_SUBSEQUENT_TIMER .. " MiniHipatternsTodo")
    vim.cmd("hi link " .. HL_COMPLETED_TIMER .. " MiniHipatternsNote")
end

local function get_namespace()
    return vim.api.nvim_create_namespace("virtualtimer")
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

vim.api.nvim_create_user_command("VTParse", function(_)
    local ns = get_namespace()

    vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    local hl_values = { HL_CURRENT_TIMER, HL_SUBSEQUENT_TIMER }

    local match_index = 1
    for i, line in ipairs(lines) do
        local match = string.match(line, "@timer%(([0-9hms]+)%)")
        if match ~= nil then
            local hl = hl_values[match_index] or hl_values[#hl_values]
            match_index = match_index + 1
            local seconds = parse_duration(match)
            vim.api.nvim_buf_set_extmark(0, ns, i - 1, 0, {
                virt_text = { { "  " .. format_seconds(seconds) .. " ", hl } }
            })
        end
    end
end, {})

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

vim.api.nvim_create_user_command("VTStart", function(_)
    local buf = vim.api.nvim_get_current_buf()

    if _G.virtualtimer.timer_id_for_buf[buf] ~= nil then
        print("Timer already running in buffer")
        return
    end

    local function timer_tick(first_tick)
        local ns = get_namespace()
        local ok, extmarks = pcall(function() return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) end)
        if not ok then
            vim.notify("Could not get list of timer marks in buffer; stopping")
            cancel_timer(buf)
            return
        end

        for i, extmark in ipairs(extmarks) do
            local id, row, col, details = table.unpack(extmark)
            local virt_text = details.virt_text
            if virt_text[1][2] == HL_CURRENT_TIMER then
                local hl = virt_text[1][2]
                local seconds = parse_virt_text_duration(virt_text[1][1])

                if not first_tick then
                    seconds = seconds - 1
                    if seconds == 0 then
                        vim.notify("Timer completed")
                        hl = HL_COMPLETED_TIMER
                    end

                    local new_virt_text = "  " .. format_seconds(seconds) .. " "
                    vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
                        id = id,
                        virt_text = { { new_virt_text, hl } }
                    })

                    if seconds == 0 and extmarks[i + 1] ~= nil then
                        -- is the next timer nearby? if so, advance to it
                        local next_id, next_row, next_col, next_details = table.unpack(extmarks[i + 1])
                        local next_virt_text = next_details.virt_text
                        if next_row == row or next_row == row + 1 and next_virt_text[1][2] == HL_SUBSEQUENT_TIMER then
                            vim.api.nvim_buf_set_extmark(buf, ns, next_row, next_col, {
                                id = next_id,
                                virt_text = { { next_virt_text[1][1], HL_CURRENT_TIMER } }
                            })
                            vim.notify("Start timer with duration " .. format_seconds(parse_virt_text_duration(next_virt_text[1][1])))
                        else
                            cancel_timer(buf)
                        end
                    end
                else
                    vim.notify("Start timer with duration " .. format_seconds(seconds))
                end
                return true
            end
        end

        vim.notify("No active timer in buffer; stopping")
        cancel_timer(buf)
        return false
    end

    if timer_tick(true) then
        _G.virtualtimer.timer_id_for_buf[buf] = vim.fn.timer_start(1000, function() timer_tick(false) end, { ["repeat"] = -1 }) -- -1 means infinite repetition
    end
end, {})

vim.api.nvim_create_user_command("VTStop", function(_)
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

