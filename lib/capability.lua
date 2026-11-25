--[[--
Capability detection for focusline.

Classifies the currently open document as one of:
  "rolling"     -- crengine-backed reflowable text (EPUB/FB2/MOBI/TXT/HTML/...)
  "paging"      -- fixed-layout document (PDF/DJVU) with a real, extractable
                   text layer (native or OCR-backed via koptinterface)
  "unsupported" -- fixed-layout document with no usable text boxes at all
                   (manga/comics/scanned images without OCR)

The result is cached for the lifetime of the document instance so repeated
calls (menu redraws, dispatcher checks, etc.) are cheap.
--]]--

local logger = require("logger")

local Capability = {}
Capability.__index = Capability

function Capability:new(o)
    o = o or {}
    setmetatable(o, self)
    o._kind = nil -- cached classification
    return o
end

-- Try a handful of pages (first few, in case page 1 is a blank/cover page)
-- looking for any page with at least one word box.
local PROBE_PAGE_COUNT = 5

function Capability:_probePagingText()
    local document = self.ui.document
    local ok_count, page_count = pcall(function() return document:getPageCount() end)
    if not ok_count or not page_count or page_count < 1 then
        page_count = 1
    end
    local last_page = math.min(page_count, PROBE_PAGE_COUNT)
    for pageno = 1, last_page do
        local ok, boxes = pcall(function() return document:getTextBoxes(pageno) end)
        if ok and boxes and #boxes > 0 then
            for _, line in ipairs(boxes) do
                if line and #line > 0 then
                    return true
                end
            end
        end
    end
    return false
end

-- Classify (and cache) the current document. Safe to call many times.
function Capability:getKind()
    if self._kind then
        return self._kind
    end
    local kind
    if self.ui.rolling then
        -- crengine always exposes a text layer for the formats it opens.
        kind = "rolling"
    elseif self.ui.paging then
        local has_text = self:_probePagingText()
        kind = has_text and "paging" or "unsupported"
    else
        kind = "unsupported"
    end
    logger.dbg("focusline: capability classified document as", kind)
    self._kind = kind
    return kind
end

function Capability:isSupported()
    local kind = self:getKind()
    return kind == "rolling" or kind == "paging"
end

function Capability:isRolling()
    return self:getKind() == "rolling"
end

function Capability:isPaging()
    return self:getKind() == "paging"
end

-- Call when the document is reflowed/rerendered in a way that could change
-- text-layer availability (rare, but cheap to support).
function Capability:reset()
    self._kind = nil
end

return Capability
