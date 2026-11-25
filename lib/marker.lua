--[[--
Pure(ish) marker logic: holds the current "unit" (word or sentence) the
marker is anchored to, and knows how to move it forward/backward,
re-derive it under a different granularity, and hand back screen boxes for
painting. Delegates all document-shape-specific work to the active
segmenter (`lib/segmenter/init.lua`).

This module does NOT touch annotations or drawing; `main.lua` wires it to
`lib/annotation_bridge.lua` (persistence) and `lib/draw.lua` (painting).
--]]--

local Event = require("ui/event")
local logger = require("logger")
local SegmenterFactory = require("lib/segmenter/init")

local Marker = {}
Marker.__index = Marker

function Marker:new(o)
    o = o or {}
    setmetatable(o, self)
    o.unit = nil -- current unit table (shape depends on segmenter)
    o._self_initiated = false -- short-lived flag, see markSelfInitiated()
    o.segmenter = SegmenterFactory.create(o.ui, o.capability)
    return o
end

function Marker:isSupported()
    return self.segmenter ~= nil
end

function Marker:getGranularity()
    return self.settings:getGranularity()
end

-- Call immediately before triggering our own page turn (GotoViewRel) so the
-- resulting onPageUpdate/onPosUpdate handler in main.lua knows this page
-- change was caused by us, not the user, and should not be treated as a
-- manual-turn auto-pause trigger.
function Marker:markSelfInitiated()
    self._self_initiated = true
end

-- Consumes (and clears) the flag; returns whether the most recent page
-- change was self-initiated.
function Marker:consumeSelfInitiated()
    local was = self._self_initiated
    self._self_initiated = false
    return was
end

-- Anchor to the first unit of the page/view currently on screen. Used on
-- enabling the plugin, on manual page turns (auto-pause re-anchor), and on
-- resume-to-marker when no saved position resolves.
function Marker:anchorToCurrentPage()
    if not self.segmenter then
        return nil
    end
    local granularity = self:getGranularity()
    local unit
    if self.ui.rolling then
        unit = self.segmenter:getFirstUnitOnScreen(granularity)
    else
        local pageno = self.ui:getCurrentPage()
        unit = self.segmenter:getFirstUnitOnPage(pageno, granularity)
    end
    self.unit = unit
    return unit
end

-- Anchor to the exact span of a saved marker item
-- (`AnnotationBridge:getMarkerAnchor()`): {pos0, pos1} xpointers for rolling
-- documents, {page, pos0, pos1} page positions for paging ones. The saved
-- boundaries are kept as they are - not re-derived from the current
-- granularity - so a hand-adjusted marker comes back as adjusted, and the
-- unit always agrees with the annotation item it was read from.
--
-- Used when reopening a book (resume / re-adopt) and after a boundary
-- adjustment. Leaves self.unit untouched and returns nil if the anchor no
-- longer resolves.
function Marker:anchorTo(anchor)
    if not self.segmenter or not anchor then
        return nil
    end
    local unit
    if self.ui.rolling then
        unit = self.segmenter:getUnitFromPositions(anchor.pos0, anchor.pos1)
    else
        unit = self.segmenter:getUnitFromPositions(anchor.page, anchor.pos0, anchor.pos1)
    end
    if unit then
        self.unit = unit
    end
    return unit
end

-- True if the current unit is on the page/view currently on screen.
function Marker:isOnScreen()
    if not self.segmenter or not self.unit then
        return false
    end
    return self.segmenter:isUnitOnScreen(self.unit)
end

-- Re-derive the current unit's boundaries under a new granularity without
-- losing position (anchored at the unit's own start).
function Marker:setGranularity(granularity, doc_only)
    self.settings:setGranularity(granularity, doc_only)
    if not self.unit or not self.segmenter then
        return
    end
    local unit
    if self.ui.rolling then
        unit = self.segmenter:getUnitAt(self.unit.pos0, granularity)
    else
        unit = self.segmenter:getUnitAt(self.unit.page, self.unit.i0, self.unit.j0, granularity)
    end
    if unit then
        self.unit = unit
    end
end

-- Returns true if `unit`'s page is reachable without further navigation
-- (rolling: just checks the unit exists; paging: checks page == current).
function Marker:_pageTurnNeededFor(diff)
    if self.ui.rolling then
        return false -- handled by isXPointerInCurrentPage inside the segmenter
    end
    return diff ~= 0
end

-- Attempt to move forward one unit. On success, updates self.unit and
-- returns true. On hitting the edge of the current page, triggers a page
-- turn (flagged self-initiated), re-anchors to the first unit of the new
-- page, and returns true. Returns false only if there is truly nowhere left
-- to go (end of document).
function Marker:moveNext()
    if not self.segmenter or not self.unit then
        return self:anchorToCurrentPage() ~= nil
    end
    local granularity = self:getGranularity()
    local next_unit = self.segmenter:nextUnit(self.unit, granularity)
    if next_unit then
        self.unit = next_unit
        return true
    end
    -- Hit the edge of the current page/view: turn the page ourselves.
    return self:_advancePage(1, granularity)
end

function Marker:movePrev()
    if not self.segmenter or not self.unit then
        return self:anchorToCurrentPage() ~= nil
    end
    local granularity = self:getGranularity()
    local prev_unit = self.segmenter:prevUnit(self.unit, granularity)
    if prev_unit then
        self.unit = prev_unit
        return true
    end
    return self:_advancePage(-1, granularity)
end

function Marker:_advancePage(direction, granularity)
    self:markSelfInitiated()
    if self.ui.rolling then
        -- ReaderRolling:onGotoViewRel always returns true, even when it
        -- can't actually move any further (true start/end of document) -
        -- in that case it just fires EndOfBook and leaves the view where it
        -- was. Detect that "didn't actually move" case ourselves by
        -- comparing the view's xpointer before/after, otherwise we'd
        -- re-anchor to the first unit of the (unchanged) current page and
        -- silently undo the end-of-book handling in main.lua.
        local before_xp = self.ui.document:getXPointer()
        local ok = self.ui:handleEvent(Event:new("GotoViewRel", direction))
        if not ok then
            return false
        end
        local after_xp = self.ui.document:getXPointer()
        if before_xp and after_xp and before_xp == after_xp then
            return false -- true start/end of document, nothing to re-anchor to
        end
        local unit = self.segmenter:getFirstUnitOnScreen(granularity)
        if direction < 0 then
            -- Prefer landing on the LAST unit of the previous page when
            -- moving backward: stepping back from the top of a page should
            -- continue at the bottom of the one before it.
            unit = self:_lastUnitOnScreen(granularity) or unit
        end
        if not unit then
            return false
        end
        self.unit = unit
        return true
    else
        local current_page = self.ui:getCurrentPage()
        local target_page = current_page + direction
        local page_count = self.ui.document:getPageCount()
        if target_page < 1 or target_page > page_count then
            return false
        end
        local ok = self.ui:handleEvent(Event:new("GotoPage", target_page))
        if not ok then
            return false
        end
        local unit
        if direction < 0 then
            unit = self.segmenter:getLastUnitOnPage(target_page, granularity)
        else
            unit = self.segmenter:getFirstUnitOnPage(target_page, granularity)
        end
        if not unit then
            return false
        end
        self.unit = unit
        return true
    end
end

-- Best-effort "last unit visible on the (new, rolling) screen" helper: used
-- only for the backward page-turn landing case above. Rolling documents
-- don't expose a direct "last word on page" API, so we binary-search
-- forward from the top of the view using nextUnit until it fails.
function Marker:_lastUnitOnScreen(granularity)
    local unit = self.segmenter:getFirstUnitOnScreen(granularity)
    if not unit then
        return nil
    end
    local guard = 0
    while guard < 2000 do
        local next_unit = self.segmenter:nextUnit(unit, granularity)
        if not next_unit then
            break
        end
        unit = next_unit
        guard = guard + 1
    end
    return unit
end

-- Screen rects for the current unit, or nil if off-screen/unavailable.
function Marker:getCurrentBoxes()
    if not self.segmenter or not self.unit then
        return nil
    end
    return self.segmenter:getScreenBoxes(self.unit)
end

-- Where the free space beside the text line that screen rect `rect` sits on
-- begins: `{ left = x, right = x }` in screen coordinates, or nil if unknown.
-- Used by lib/draw.lua to put the edge icon beside the line instead of on
-- top of the words next to a marker that starts or ends mid-line.
function Marker:getLineBounds(rect)
    if not self.segmenter or not self.unit or not rect then
        return nil
    end
    return self.segmenter:getLineBounds(self.unit, rect)
end

-- A stable, serializable anchor for the current unit, suitable for
-- `lib/resume.lua` and `lib/annotation_bridge.lua`.
function Marker:getAnchor()
    if not self.unit then
        return nil
    end
    if self.ui.rolling then
        return { pos0 = self.unit.pos0, pos1 = self.unit.pos1 }
    else
        return {
            page = self.unit.page,
            i0 = self.unit.i0, j0 = self.unit.j0,
            i1 = self.unit.i1, j1 = self.unit.j1,
        }
    end
end

function Marker:clear()
    self.unit = nil
end

return Marker
