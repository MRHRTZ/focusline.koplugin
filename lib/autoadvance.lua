--[[--
Auto-advance timer: calls back into `main.lua` every N ms to move the
marker forward one unit, using `UIManager:scheduleIn`/`unschedule` (no
blocking sleeps, cooperates with the rest of the UI event loop).

Independent on/off switch from the main plugin enable/disable: the timer can be running only while both the plugin is
enabled AND the auto-advance toggle is on; either turning off stops it.

Pauses automatically (without flipping the user's "enabled" setting) when
the surrounding code detects a manual, non-self-initiated page turn - see
`main.lua`'s auto-pause handling, which calls `pause()` directly rather
than `stop()`/`isAutoAdvanceEnabled(false)` so the toggle itself is left
alone and a subsequent explicit "resume" menu action can restart it.
--]]--

local UIManager = require("ui/uimanager")
local logger = require("logger")

local MIN_MS = 200 -- sane floor; guards against runaway/typo'd tiny intervals

local AutoAdvance = {}
AutoAdvance.__index = AutoAdvance

-- on_tick: function() -> boolean "keep going" (false/nil stops the timer,
--          e.g. when moveNext() reports end-of-document).
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

function AutoAdvance:_getIntervalSeconds()
    local ms = self.settings:getAutoAdvanceMs() or 4000
    if ms < MIN_MS then
        ms = MIN_MS
    end
    return ms / 1000
end

function AutoAdvance:_scheduleNext()
    self._scheduled_action = function()
        self:_onTick()
    end
    UIManager:scheduleIn(self:_getIntervalSeconds(), self._scheduled_action)
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
    self:_scheduleNext()
end

-- Start (or restart, picking up any new interval) the timer.
function AutoAdvance:start()
    self:stop() -- clear any pending tick first, avoid double-scheduling
    self._running = true
    self:_scheduleNext()
    logger.dbg("focusline: auto-advance started, interval ms =", self.settings:getAutoAdvanceMs())
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
