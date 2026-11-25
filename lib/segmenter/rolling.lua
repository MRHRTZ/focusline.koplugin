--[[--
Word/sentence segmenter for rolling (crengine-backed) documents.

Works entirely in terms of xpointers (`document:getPosFromXPointer`,
`getNextVisibleWordStart`, etc.) so it is agnostic to screen position; the
marker's current "unit" is always a `{ pos0 = xpointer, pos1 = xpointer,
text = string }` table.

Sentence segmentation walks word-by-word using the same shared
`sentence_rules.lua` terminal-word heuristic the paging segmenter uses,
rather than crengine's own `extendXPointersToSentenceSegment`. That API
looks similar but does something different: it only nudges an *existing*
selection's edges outward to swallow adjacent punctuation/quotes (used by
"highlight a selection, extend to sentence"), and returns nil whenever the
given span doesn't already sit at what it considers a sentence boundary -
which is true for almost any single mid-sentence word. Relying on it here
silently collapsed sentence mode into word-by-word movement. Walking
forward/backward ourselves until a terminal word (per sentence_rules) is
found gives an actual "whole sentence" span, matching paging.lua.

A sentence also ends where its block of text ends (heading, paragraph, list
item, ...), so a heading with no full stop is its own unit instead of being
glued onto the first sentence of the paragraph below it - see
`SentenceRules.isBlockBreak`.
--]]--

local SentenceRules = require("lib/segmenter/sentence_rules")
local logger = require("logger")

local RollingSegmenter = {}
RollingSegmenter.__index = RollingSegmenter

-- Walking forward/backward over an entire book should never infinite-loop,
-- but cap it defensively (a single sentence/paragraph longer than this is
-- not realistic, and this bounds worst-case cost if some edge case feeds
-- back the same xpointer forever).
local WALK_GUARD = 4000

function RollingSegmenter:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- Build a unit table from a single xpointer representing the (approximate)
-- start of a word. Returns nil if no word can be found there.
function RollingSegmenter:_wordUnitAt(xp)
    local document = self.ui.document
    -- getWordFromPosition needs a screen-space-ish pos table; it's also
    -- usable with just the xpointer-derived pos since CreDocument resolves
    -- coordinates through the engine. We instead use the xpointer-based
    -- word walk: start is xp itself, end is getNextVisibleWordEnd(xp).
    local pos1 = document:getNextVisibleWordEnd(xp)
    if not pos1 then
        return nil
    end
    local text = document:getTextFromXPointers(xp, pos1)
    return { pos0 = xp, pos1 = pos1, text = text }
end

-- True if word unit `b` (the word right after `a`) is in a different block of
-- text than `a`: a heading and the paragraph under it, two paragraphs, two
-- list items, two lines of verse.
--
-- Read off the text spanning both words, start of `a` to end of `b`: crengine
-- puts a newline there when the two sit in different blocks, and words never
-- contain one themselves. The text of just the gap BETWEEN them (end of `a`
-- to start of `b`) can't be used for this: when `a` is the last thing in its
-- block and `b` the first in the next, that range is empty and the newline
-- is not reported.
function RollingSegmenter:_isBlockBreakBetween(a, b)
    if not a or not b then
        return false
    end
    local ok, span = pcall(self.ui.document.getTextFromXPointers, self.ui.document, a.pos0, b.pos1)
    return ok and SentenceRules.isBlockBreak(span) or false
end

-- Walk backward from `xp` (exclusive) looking for the nearest preceding
-- terminal word; the sentence containing `xp` starts right after it (or at
-- the very start of the document if none is found). Mirrors
-- PagingSegmenter:_sentenceStartContaining, word-start xpointers instead of
-- (line,word) indices.
function RollingSegmenter:_sentenceStartContaining(xp)
    local document = self.ui.document
    local cur = xp
    local guard = 0
    while guard < WALK_GUARD do
        local prev_start = document:getPrevVisibleWordStart(cur)
        if not prev_start or prev_start == cur then
            return cur -- walked back to the start of the document
        end
        local prev_unit = self:_wordUnitAt(prev_start)
        if prev_unit then
            -- The gap between this earlier word's end and `cur` (where we
            -- started walking from) is where any terminal punctuation
            -- actually lives (see the comment in _sentenceUnitFrom).
            local gap = document:getTextFromXPointers(prev_unit.pos1, cur) or ""
            if SentenceRules.isTerminalGap(gap, prev_unit.text)
                or self:_isBlockBreakBetween(prev_unit, self:_wordUnitAt(cur)) then
                -- The sentence starts at the word right after this terminal
                -- one, i.e. back where we started walking from this
                -- iteration.
                return cur
            end
        end
        cur = prev_start
        guard = guard + 1
    end
    logger.warn("focusline: _sentenceStartContaining hit WALK_GUARD")
    return cur
end

-- Walk forward from `pos0` (the start of the first word of the sentence)
-- accumulating words until a terminal word is found or the document ends.
-- Mirrors PagingSegmenter:_sentenceUnitFrom.
function RollingSegmenter:_sentenceUnitFrom(pos0)
    local document = self.ui.document
    local unit = self:_wordUnitAt(pos0)
    if not unit then
        return nil
    end
    local last_pos1 = unit.pos1
    local guard = 0
    while guard < WALK_GUARD do
        local next_start = document:getNextVisibleWordStart(unit.pos1)
        if not next_start then
            break -- end of document
        end
        -- crengine's word walk skips punctuation entirely - "dog." yields a
        -- word whose text is just "dog", with the period never appearing in
        -- any word's own text. The terminal-word check therefore needs to
        -- look at the gap between this word's end and the next word's
        -- start (where the period/comma/etc actually lives), not the word
        -- text itself.
        -- A sentence also stops where its block of text does (a heading and
        -- the paragraph under it, two list items, ...), punctuation or not -
        -- see _isBlockBreakBetween below.
        local gap = document:getTextFromXPointers(unit.pos1, next_start) or ""
        if SentenceRules.isTerminalGap(gap, unit.text) then
            break
        end
        local next_unit = self:_wordUnitAt(next_start)
        if not next_unit then
            break
        end
        if self:_isBlockBreakBetween(unit, next_unit) then
            break
        end
        unit = next_unit
        last_pos1 = unit.pos1
        guard = guard + 1
    end
    local text = document:getTextFromXPointers(pos0, last_pos1)
    return { pos0 = pos0, pos1 = last_pos1, text = text }
end

-- Current unit (word or sentence) containing / starting at `anchor_xp`.
-- `granularity` is "word" or "sentence".
function RollingSegmenter:getUnitAt(anchor_xp, granularity)
    if not anchor_xp then
        return nil
    end
    if granularity == "sentence" then
        local sentence_start = self:_sentenceStartContaining(anchor_xp)
        return self:_sentenceUnitFrom(sentence_start)
    else
        return self:_wordUnitAt(anchor_xp)
    end
end

-- Rebuild a unit from an exact, previously saved xpointer range (the marker's
-- own annotation item), WITHOUT re-deriving its boundaries from the current
-- granularity. Returns nil if either xpointer no longer resolves in this
-- document or the range is reversed/empty.
function RollingSegmenter:getUnitFromPositions(pos0, pos1)
    if type(pos0) ~= "string" or type(pos1) ~= "string" then
        return nil
    end
    local document = self.ui.document
    local ok, order = pcall(document.compareXPointers, document, pos0, pos1)
    if not ok or order ~= 1 then
        return nil
    end
    local ok_text, text = pcall(document.getTextFromXPointers, document, pos0, pos1)
    if not ok_text or not text or text == "" then
        return nil
    end
    return { pos0 = pos0, pos1 = pos1, text = text }
end

-- True if `unit` starts on the page/view currently on screen.
function RollingSegmenter:isUnitOnScreen(unit)
    if not unit or not unit.pos0 then
        return false
    end
    local ok, visible = pcall(function()
        return self.ui.document:isXPointerInCurrentPage(unit.pos0)
    end)
    return ok and visible and true or false
end

-- Start of the first word on the page currently on screen.
--
-- `getNextVisibleWordStart(top)` alone is not it: it always moves PAST the
-- word `top` is on, so when the top of the page is itself the start of a
-- word (the usual case) that first word would be skipped - "Chapter" in a
-- page that opens with "Chapter One", or the first word of any page that
-- starts mid-paragraph. So step forward one word, then back one: if that
-- lands at or after the top of the page it is the page's real first word.
-- If it lands before the top (the page starts in the middle of a hyphenated
-- word whose start is on the previous page), keep the forward result.
function RollingSegmenter:_firstWordStartOnScreen()
    local document = self.ui.document
    local top_xp = document:getXPointer() -- top of current view
    if not top_xp then
        return nil
    end
    local next_start = document:getNextVisibleWordStart(top_xp)
    if not next_start then
        return top_xp
    end
    local prev_start = document:getPrevVisibleWordStart(next_start)
    if prev_start and prev_start ~= next_start then
        local ok, order = pcall(document.compareXPointers, document, top_xp, prev_start)
        if ok and (order == 0 or order == 1) then
            return prev_start
        end
    end
    return next_start
end

-- First unit on the page currently on screen (used when re-anchoring after
-- a manual page turn, or on first enabling the plugin). For sentence mode,
-- this deliberately starts a fresh sentence span at the first visible word
-- rather than walking back into the previous (now off-screen) page - the
-- re-anchored marker should always land on something currently visible.
function RollingSegmenter:getFirstUnitOnScreen(granularity)
    local word_start = self:_firstWordStartOnScreen()
    if not word_start then
        return nil
    end
    if granularity == "sentence" then
        return self:_sentenceUnitFrom(word_start)
    else
        return self:_wordUnitAt(word_start)
    end
end

-- Move forward/backward by one unit from `unit`'s anchor (its pos0).
-- Returns the new unit, or nil if there is no next/previous unit (caller
-- should then trigger a page turn and re-anchor).
function RollingSegmenter:nextUnit(unit, granularity)
    local document = self.ui.document
    if not unit then
        return nil
    end
    if granularity == "sentence" then
        -- Jump past the end of the current sentence to the next word start,
        -- which is exactly the start of the next sentence - no need to walk
        -- backward again.
        local next_word_start = document:getNextVisibleWordStart(unit.pos1)
        if not next_word_start then
            return nil
        end
        if not document:isXPointerInCurrentPage(next_word_start) then
            return nil -- caller handles page turn
        end
        return self:_sentenceUnitFrom(next_word_start)
    else
        local next_word_start = document:getNextVisibleWordStart(unit.pos0)
        if not next_word_start or next_word_start == unit.pos0 then
            return nil
        end
        if not document:isXPointerInCurrentPage(next_word_start) then
            return nil
        end
        return self:getUnitAt(next_word_start, granularity)
    end
end

function RollingSegmenter:prevUnit(unit, granularity)
    local document = self.ui.document
    if not unit then
        return nil
    end
    local prev_word_start = document:getPrevVisibleWordStart(unit.pos0)
    if not prev_word_start or prev_word_start == unit.pos0 then
        return nil
    end
    if not document:isXPointerInCurrentPage(prev_word_start) then
        return nil
    end
    if granularity == "sentence" then
        -- prev_word_start now sits inside (or at the end of) the previous
        -- sentence; find the start of whichever sentence contains it, then
        -- build its full span.
        local prev_sentence_start = self:_sentenceStartContaining(prev_word_start)
        return self:_sentenceUnitFrom(prev_sentence_start)
    else
        return self:_wordUnitAt(prev_word_start)
    end
end

-- True if the word starting at `word_start` is drawn on the same text line as
-- screen rect `rect`.
function RollingSegmenter:_wordSharesLine(word_start, rect)
    local word = word_start and self:_wordUnitAt(word_start)
    if not word then
        return false
    end
    local document = self.ui.document
    local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, word.pos0, word.pos1, true)
    if not ok or type(boxes) ~= "table" then
        return false
    end
    local mid_y = rect.y + rect.h / 2
    for _, box in ipairs(boxes) do
        if mid_y >= box.y and mid_y <= box.y + box.h then
            return true
        end
    end
    return false
end

-- Where the free space beside the text line that `rect` (one of `unit`'s
-- screen rects) is on begins, on either side.
--
-- A unit's rects are cut per line, so text can only sit beside one of them
-- where the unit starts or ends in the middle of a line: the word before the
-- unit on the first line, the word after it on the last. Where there is such
-- a neighbour, the free space only begins at the page margin (text never
-- extends into it, however the line is indented or aligned); where there is
-- none, it begins right at the rect - which is what lets an indented first
-- line, or a short last line, keep a full-size icon.
function RollingSegmenter:getLineBounds(unit, rect)
    local document = self.ui.document
    local left, right = rect.x, rect.x + rect.w

    local prev_start = document:getPrevVisibleWordStart(unit.pos0)
    local next_start = document:getNextVisibleWordStart(unit.pos1)
    local text_on_left = prev_start and prev_start ~= unit.pos0 and self:_wordSharesLine(prev_start, rect)
    local text_on_right = next_start and self:_wordSharesLine(next_start, rect)
    if not text_on_left and not text_on_right then
        return { left = left, right = right }
    end

    local margins = document:getPageMargins()
    local screen_w = self.ui.dimen and self.ui.dimen.w
    if not margins or not margins.left or not margins.right or not screen_w then
        -- Can't tell where the line ends: claim no free space at all, so the
        -- icon is squeezed to its minimum rather than drawn over text.
        return { left = text_on_left and 0 or left, right = text_on_right and screen_w or right }
    end
    local page_left, page_right = margins.left, screen_w - margins.right
    if self.ui.view.view_mode == "page" and document:getVisiblePageCount() > 1 then
        -- Two pages side by side: each has its own pair of margins.
        local page2_x = document:getPageOffsetX(document:getCurrentPage(true) + 1)
        if page2_x and page2_x > 0 then
            if rect.x >= page2_x then
                page_left = page2_x + margins.left
            else
                page_right = page_right - page2_x
            end
        end
    end
    if text_on_left then
        left = math.min(left, page_left)
    end
    if text_on_right then
        right = math.max(right, page_right)
    end
    return { left = left, right = right }
end

-- Screen rects for a unit (array of Geom-like {x,y,w,h}), segmented per
-- line, suitable both for painting and for feeding into annotation pboxes.
function RollingSegmenter:getScreenBoxes(unit)
    if not unit or not unit.pos0 or not unit.pos1 then
        return nil
    end
    local ok, boxes = pcall(function()
        return self.ui.document:getScreenBoxesFromPositions(unit.pos0, unit.pos1, true)
    end)
    if not ok then
        logger.warn("focusline: getScreenBoxes failed", boxes)
        return nil
    end
    return boxes
end

return RollingSegmenter
