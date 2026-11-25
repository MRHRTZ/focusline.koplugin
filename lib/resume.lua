--[[--
Resume-to-marker: independently of KOReader's own "last read position",
optionally jump straight to the saved marker position when a book is
reopened.

The marker's own annotation item (see lib/annotation_bridge.lua) already
*is* the persisted position - we don't need a second storage location for
"where was I": we just read the existing marker item (if any) back out of
`ui.annotation.annotations` once the document is ready, and ask
`lib/marker.lua` to anchor there.
--]]--

local Event = require("ui/event")
local logger = require("logger")

local Resume = {}
Resume.__index = Resume

function Resume:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- Navigate to the page holding the marker's current unit. Called from
-- main.lua's _restoreMarker() AFTER it has re-anchored the marker to the
-- saved item, and only when that unit is not already on screen - a marker
-- that is already visible needs no navigation at all, whatever this setting
-- says. Returns true if the marker is on screen afterwards.
function Resume:jumpToMarker()
    if not self.settings:isResumeEnabled() then
        return false
    end
    local unit = self.marker.unit
    if not unit then
        return false
    end
    -- The GotoXPointer/GotoPage below fires a PosUpdate/PageUpdate event that
    -- main.lua also listens to (for auto-pause/re-anchor on MANUAL turns);
    -- mark this one self-initiated so that handler doesn't immediately
    -- override our precise resumed unit with "first unit on page".
    self.marker:markSelfInitiated()
    local ok = false
    if self.ui.rolling then
        -- IMPORTANT: must go through the "GotoXPointer" event (handled by
        -- ReaderRolling:onGotoXPointer), NOT call document:gotoXPointer()
        -- directly. The latter is, per KOReader's own credocument.lua
        -- comment, "for cre internal fixup" only: it repositions crengine's
        -- internal cursor but does NOT update ReaderView's rendered
        -- page/pos state. In the (very common) paged "view_mode", the view
        -- is painted from `ReaderView.state.page`, which is only ever
        -- updated by a real "PageUpdate" event - so a raw gotoXPointer()
        -- here would silently move the underlying document position while
        -- leaving the visible page exactly where it was, which is the
        -- "marker jumps back to the top on reopen" bug. onGotoXPointer()
        -- correctly branches page-vs-scroll view_mode and fires the right
        -- event either way (mirrors readertoc.lua/readerlink.lua/
        -- readersearch.lua, which all use this same event to jump to a
        -- saved xpointer).
        ok = self.ui:handleEvent(Event:new("GotoXPointer", unit.pos0))
    else
        ok = self.ui:handleEvent(Event:new("GotoPage", unit.page))
    end
    -- Event dispatch is synchronous, so main.lua's handler has already
    -- consumed the flag if a PageUpdate/PosUpdate fired. If none did (the
    -- target turned out to be the page already shown), drop it here - left
    -- set, it would swallow the reader's next real page turn.
    self.marker:consumeSelfInitiated()
    if ok and self.marker:isOnScreen() then
        logger.dbg("focusline: resumed to marker position")
        return true
    end
    return false
end

return Resume
