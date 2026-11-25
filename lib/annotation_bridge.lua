--[[--
Bridges the marker's current unit (from `lib/marker.lua`) to KOReader's real
annotation/highlight machinery (`ui.annotation`, `ui.highlight`,
`ui.bookmark`), so the marker is a normal, saved, deletable highlight - not
a custom overlay.

Exactly one annotation item is "the marker" at a time, tagged with
`item.focusline_marker = true`. Moving the marker never inserts a second
item: it deletes-then-reinserts (position determines sort order in
`annotations`, so an in-place field mutation isn't safe - mirrors how
`ReaderHighlight:editHighlightStyle` does delete-then-save for PDF writes).

Public API:
  setMarker(unit, template)   -- replace (or create) the marker at `unit`
  clearMarker()               -- remove the marker item, if any
  isMarkerPresent()           -- true if our tagged item is still in
                                  ui.annotation.annotations (false if the
                                  user deleted it via stock highlight UI)
  getMarkerAnchor()           -- {pos0,pos1,page,...} of the live item, or
                                  nil
  getMarkerIndex()            -- current index, item (or nil)
  getMarkerItem()             -- the live item table (or nil)
  restyleMarker(template)     -- change drawer/color in place, no move
--]]--

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")

-- No default note: the marker should be a plain highlight unless the user
-- adds their own note via the stock highlight-edit dialog's "Note" button
-- (which this bridge then carries forward across moves, see setMarker()).
local MARKER_NOTE = nil

local AnnotationBridge = {}
AnnotationBridge.__index = AnnotationBridge

function AnnotationBridge:new(o)
    o = o or {}
    setmetatable(o, self)
    o.marker_item = nil -- live reference to the annotation item table, or nil
    return o
end

function AnnotationBridge:_findMarkerIndex()
    local annotations = self.ui.annotation.annotations
    if self.marker_item then
        for i, item in ipairs(annotations) do
            if item == self.marker_item then
                return i, item
            end
        end
        -- Reference no longer present (user deleted it, or doc reloaded).
        self.marker_item = nil
    end
    -- Fall back to a flag scan, in case marker_item was lost (e.g. plugin
    -- instance recreated but annotations persisted from sidecar file).
    for i, item in ipairs(annotations) do
        if item.focusline_marker then
            return i, item
        end
    end
    return nil
end

function AnnotationBridge:isMarkerPresent()
    return self:_findMarkerIndex() ~= nil
end

-- Current index of the marker in ui.annotation.annotations (plus the item
-- itself), or nil. Never cache the index: every marker move deletes and
-- re-inserts the item, and any other highlight being added/removed shifts it.
function AnnotationBridge:getMarkerIndex()
    return self:_findMarkerIndex()
end

function AnnotationBridge:getMarkerItem()
    local _, item = self:_findMarkerIndex()
    return item
end

-- Where the saved marker item sits, in the shape lib/marker.lua's anchorTo()
-- takes. These are the item's EXACT boundaries, so a marker whose start/end
-- was nudged by hand (the popup's "Adjust") is restored as nudged.
function AnnotationBridge:getMarkerAnchor()
    local _, item = self:_findMarkerIndex()
    if not item then
        return nil
    end
    if self.ui.rolling then
        return { pos0 = item.pos0, pos1 = item.pos1 }
    else
        local page = type(item.pos0) == "table" and item.pos0.page or item.page
        return { page = page, pos0 = item.pos0, pos1 = item.pos1 }
    end
end

-- Build the annotation item table for `unit` (shape from lib/marker.lua's
-- getAnchor-compatible unit) using `template`'s drawer kind + color.
function AnnotationBridge:_buildItem(unit, template)
    local pg_or_xp
    local item = {
        pos0 = unit.pos0,
        pos1 = unit.pos1,
        text = unit.text and util.cleanupSelectedText(unit.text) or "",
        drawer = template.drawer,
        color = template.color,
        note = MARKER_NOTE,
        focusline_marker = true,
        focusline_template_id = template.id,
    }
    if self.ui.paging then
        pg_or_xp = unit.pos0.page
        item.page = unit.pos0.page
        item.pboxes = unit.boxes
    else
        pg_or_xp = unit.pos0
        item.page = unit.pos0
        local ok, epubcfi = pcall(function()
            return self.ui.document:getEPubCFIRangeFromXPointers(item.pos0, item.pos1)
        end)
        if ok then
            item.epubcfi = epubcfi
        end
    end
    local ok_chapter, chapter = pcall(function()
        return self.ui.highlight:getHighlightChapter(pg_or_xp)
    end)
    if ok_chapter then
        item.chapter = chapter
    end
    return item
end

-- Remove the current marker item (if any), writing through to PDF native
-- annotations when that stock option is enabled, and firing the same
-- `AnnotationsModified` event ReaderBookmark:removeItemByIndex fires so the
-- footer/stats/UI stay in sync.
function AnnotationBridge:clearMarker()
    local index, item = self:_findMarkerIndex()
    if not index then
        self.marker_item = nil
        return
    end
    local ok, err = pcall(function()
        self.ui.highlight:writePdfAnnotation("delete", item)
    end)
    if not ok then
        logger.warn("focusline: writePdfAnnotation delete failed", err)
    end
    table.remove(self.ui.annotation.annotations, index)
    self.ui:handleEvent(Event:new("AnnotationsModified",
        { item, nb_highlights_added = -1, index_modified = -index }))
    if self.view.footer then
        self.view.footer:maybeUpdateFooter()
    end
    if self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
    self.marker_item = nil
end

-- Create or move the marker to `unit`. `template` ({ id, drawer, color },
-- see lib/templates.lua) is only the FALLBACK style used when there is no
-- existing marker to carry a style forward from (i.e. first placement).
--
-- When a marker already exists, its live style/note win over `template`:
-- KOReader's stock highlight-edit dialog (ReaderHighlight:editHighlightColor/
-- editHighlightStyle/editHighlightDialog's Note button, readerhighlight.lua)
-- mutates `item.drawer`/`item.color`/`item.note` IN PLACE on the very table
-- `self.marker_item` references. If we rebuilt the item from `template`
-- (always re-derived from global/doc settings) on every move, any such
-- direct edit would be silently discarded the next time the marker moves -
-- the style/color would "reset" back to the plugin default. Carrying the
-- existing item's style/note forward here is what makes a manual restyle
-- stick across moves; restyleMarker() (driven by main.lua's
-- onStyleChanged/onEdgeImageChanged/onEdgeImageEnabledToggled/onColorChanged)
-- remains the only path that *intentionally* changes style from settings/the
-- style or edge-image picker.
function AnnotationBridge:setMarker(unit, template)
    if not unit or not unit.pos0 or not unit.pos1 then
        return nil
    end
    local _, existing = self:_findMarkerIndex()
    local effective_template = template
    local carried_note = nil
    if existing then
        effective_template = {
            id = existing.focusline_template_id or template.id,
            drawer = existing.drawer,
            color = existing.color,
        }
        carried_note = existing.note
    end
    self:clearMarker()
    local item = self:_buildItem(unit, effective_template)
    if existing then
        item.note = carried_note
    end
    local index = self.ui.annotation:addItem(item)
    self.marker_item = item
    if self.ui.paging then
        local ok, err = pcall(function()
            self.ui.highlight:writePdfAnnotation("save", item)
        end)
        if not ok then
            logger.warn("focusline: writePdfAnnotation save failed", err)
        end
    end
    self.ui:handleEvent(Event:new("AnnotationsModified",
        { item, nb_highlights_added = 1, index_modified = index }))
    if self.view.footer then
        self.view.footer:maybeUpdateFooter()
    end
    if self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
    return index
end

-- Update just the style (drawer/color) of the existing marker without
-- moving it - used by the quick-style-cycle action. Cheaper than a full
-- setMarker() since the position/text/chapter are unchanged.
function AnnotationBridge:restyleMarker(template)
    local index, item = self:_findMarkerIndex()
    if not index then
        return false
    end
    if item.drawer == template.drawer and item.color == template.color
        and item.focusline_template_id == template.id then
        -- Already styled this way: nothing to write (and no reason to bump
        -- the item's modification time). Still repaint, in case what changed
        -- is something only lib/draw.lua reads live from settings.
        if self.ui.dialog then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        return true
    end
    local ok, err = pcall(function()
        self.ui.highlight:writePdfAnnotation("delete", item)
    end)
    if not ok then
        logger.warn("focusline: writePdfAnnotation delete (restyle) failed", err)
    end
    item.drawer = template.drawer
    item.color = template.color
    item.focusline_template_id = template.id
    if self.ui.paging then
        local ok2, err2 = pcall(function()
            self.ui.highlight:writePdfAnnotation("save", item)
        end)
        if not ok2 then
            logger.warn("focusline: writePdfAnnotation save (restyle) failed", err2)
        end
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", { item }))
    if self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
    return true
end

return AnnotationBridge
