--[[--
Auto-advance timer: calls back into `main.lua` to move the marker forward
one unit at a time, using `UIManager:scheduleIn`/`unschedule` (no blocking
sleeps, cooperates with the rest of the UI event loop).

How long the marker stays on each unit depends on the mode
(`Settings:getAutoAdvanceMode()`):

  "manual"  the same fixed time on every unit: `getAutoAdvanceMs()`.
  "auto"    worked out from the unit itself: the number of words in the
            marked text, at the reading speed `getAutoAdvanceWpm()` (words per
            minute). A long sentence is given longer than a short one, and in
            word granularity every word gets the time one word takes.

Independent on/off switch from the main plugin enable/disable: the timer can
be running only while both the plugin is enabled AND the auto-advance toggle
is on; either turning off stops it.

Pauses automatically (without flipping the user's "enabled" setting) when
the surrounding code detects a manual, non-self-initiated page turn - see
`main.lua`'s auto-pause handling, which calls `pause()` directly rather
than `stop()`/`isAutoAdvanceEnabled(false)` so the toggle itself is left
alone and a later start() can pick it up again.
--]]--

local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")

local MIN_MS = 200 -- sane floor; guards against runaway/typo'd tiny intervals
local MAX_AUTO_MS = 120000 -- "auto" mode: never sit on one unit longer than this

local AutoAdvance = {}
AutoAdvance.__index = AutoAdvance

-- on_tick:  function() -> boolean "keep going" (false/nil stops the timer,
--           e.g. when moveNext() reports end-of-document).
-- get_text: function() -> the text the marker is on right now, or nil. Only
--           used in "auto" mode.
function AutoAdvance:new(o)
    o = o or {}
    setmetatable(o, self)
    o._scheduled_action = nil -- reference needed for UIManager:unschedule
    o._running = false
    return o
end

function AutoAdvance:isRunning()
    return self._running
end

-- Number of words in `text`. util.splitToWords returns the words together
-- with the spaces and punctuation between them, so only the entries with a
-- letter or a digit in them are counted (a byte above 127 is part of a
-- non-ASCII letter). It splits CJK text per character, so there every
-- character counts as a word.
function AutoAdvance.countWords(text)
    if type(text) ~= "string" or text == "" then
        return 0
    end
    local count = 0
    for _, piece in ipairs(util.splitToWords(text)) do
        if piece:find("[%w\128-\255]") then
            count = count + 1
        end
    end
    return count
end

-- Time to read `text` at `wpm` words per minute, in ms.
function AutoAdvance.readingTimeMs(text, wpm)
    local words = math.max(1, AutoAdvance.countWords(text))
    return math.floor(words * 60000 / math.max(1, wpm) + 0.5)
end

-- How long the marker stays where it is now, in ms.
function AutoAdvance:getCurrentDelayMs()
    local ms
    if self.settings:getAutoAdvanceMode() == "auto" then
        local text = self.get_text and self.get_text()
        ms = math.min(MAX_AUTO_MS, AutoAdvance.readingTimeMs(text, self.settings:getAutoAdvanceWpm() or 200))
    else
        ms = self.settings:getAutoAdvanceMs() or 4000
    end
    if ms < MIN_MS then
        ms = MIN_MS
    end
    return ms
end

function AutoAdvance:_scheduleNext()
    self._scheduled_action = function()
        self:_onTick()
    end
    UIManager:scheduleIn(self:getCurrentDelayMs() / 1000, self._scheduled_action)
end

function AutoAdvance:_onTick()
    if not self._running then
        return
    end
    local keep_going = self.on_tick()
    if keep_going == false then
        self:stop()
        return
    end
    -- The marker has moved: the next wait is for the unit it is on now.
    self:_scheduleNext()
end

-- Start (or restart, picking up any new mode/interval, and giving the unit
-- the marker is on now its full time) the timer.
function AutoAdvance:start()
    self:stop() -- clear any pending tick first, avoid double-scheduling
    self._running = true
    self:_scheduleNext()
    logger.dbg("focusline: auto-advance started, mode =", self.settings:getAutoAdvanceMode(),
        "first delay ms =", self:getCurrentDelayMs())
end

-- Pause without touching the user's auto_advance_enabled setting - used by
-- auto-pause-on-manual-turn. Resumable via start().
function AutoAdvance:pause()
    if self._scheduled_action then
        UIManager:unschedule(self._scheduled_action)
        self._scheduled_action = nil
    end
    self._running = false
end

-- Full stop: same effect as pause() at the timer level; kept as a distinct
-- name for callsites that mean "the feature is now off" rather than "we're
-- just pausing for a manual turn".
function AutoAdvance:stop()
    self:pause()
end

return AutoAdvance
