--[[--
Word/sentence segmenter for paging documents (PDF/DJVU) with a real text
layer, built directly on top of `koptinterface.lua`'s per-page line/word box
arrays (`document:getTextBoxes(pageno)` -> `boxes[line_i][word_j] =
{x0,y0,x1,y1,word}`, in native page coordinates, no xpointers).

A unit is identified by page number + (line index, word index) range:

    {
        page = pageno,
        i0, j0, i1, j1,   -- inclusive line/word index range
        pos0 = {x=.., y=.., page=pageno}, -- center of the start word box
        pos1 = {x=.., y=.., page=pageno}, -- center of the end word box
        text = "...",
        boxes = { {x=,y=,w=,h=}, ... },   -- per-line rects, native page coords
    }

`pos0`/`pos1` are the *center points* of their word boxes rather than
corners: koptinterface's own nearest-box search (`getWordBoxIndices`) picks
the box whose center is closest to a given point, so handing back a box's
own center guarantees we re-resolve to the exact same box later (distance
0), which is what the annotation bridge and the "move" logic rely on.

Sentences never cross a page boundary (mirrors
`ReaderHighlight:updateHighlightPaging`, which does the same for the same
reason: box arrays are only valid within one page). Word units cross page
boundaries fine. the marker/auto-advance layer is responsible for turning
the page and re-anchoring with `getFirstUnitOnPage`/`getLastUnitOnPage`.
--]]--

local SentenceRules = require("lib/segmenter/sentence_rules")
local logger = require("logger")

local PagingSegmenter = {}
PagingSegmenter.__index = PagingSegmenter

function PagingSegmenter:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

function PagingSegmenter:_getBoxes(pageno)
    local ok, boxes = pcall(function()
        return self.ui.document:getTextBoxes(pageno)
    end)
    if not ok or not boxes then
        logger.warn("focusline: getTextBoxes failed for page", pageno, boxes)
        return nil
    end
    return boxes
end

-- First non-empty (line, word) index at or after `i`, scanning forward.
local function firstWordFrom(boxes, i)
    for li = i, #boxes do
        local line = boxes[li]
        if line and #line > 0 then
            return li, 1
        end
    end
    return nil
end

-- Last non-empty (line, word) index at or before `i`, scanning backward.
local function lastWordFrom(boxes, i)
    for li = i, 1, -1 do
        local line = boxes[li]
        if line and #line > 0 then
            return li, #line
        end
    end
    return nil
end

-- Step one word forward; returns new (i,j) or nil at end of page.
local function stepForward(boxes, i, j)
    local line = boxes[i]
    if line and j < #line then
        return i, j + 1
    end
    return firstWordFrom(boxes, i + 1)
end

-- Step one word backward; returns new (i,j) or nil at start of page.
local function stepBackward(boxes, i, j)
    if j > 1 then
        return i, j - 1
    end
    return lastWordFrom(boxes, i - 1)
end

local function boxCenter(box)
    return { x = (box.x0 + box.x1) / 2, y = (box.y0 + box.y1) / 2 }
end

-- Block breaks ---------------------------------------------------------------
--
-- A fixed-layout page has no paragraph/heading structure to ask about, only
-- lines of word boxes - so where one block of text ends and the next begins
-- has to be read off the geometry. Two signals, either is enough:
--
--   * extra vertical space: the step down to the next line is clearly larger
--     than the page's usual line-to-line step (a blank line between
--     paragraphs, the space under a heading);
--   * a change of text size: the next line is clearly taller or shorter than
--     this one (a heading above body text, a caption under it).
--
-- A sentence never runs across such a break, even when the line before it has
-- no full stop (headings and titles usually don't). Paragraphs marked only by
-- a first-line indent, with no extra space, are not detected - those still
-- rely on punctuation, exactly as before.

local PITCH_BREAK_RATIO = 1.4 -- step to next line vs. the page's usual step
local HEIGHT_BREAK_RATIO = 1.5 -- taller line vs. shorter line
local LONE_PITCH_RATIO = 2.2 -- step vs. line height, when the page has too few lines to know its usual step

-- boxes table -> { [line_i] = true if a block ends after line_i }. Weak keys:
-- entries go away with the page's box array itself.
local break_cache = setmetatable({}, { __mode = "k" })

local function lineHeight(line)
    if line and line.y0 and line.y1 then
        return line.y1 - line.y0
    end
end

local function blockBreaks(boxes)
    local cached = break_cache[boxes]
    if cached then
        return cached
    end
    local breaks = {}
    break_cache[boxes] = breaks

    -- Consecutive non-empty lines, and the step down from each to the next.
    local lines = {}
    for i = 1, #boxes do
        local line = boxes[i]
        if line and #line > 0 and line.y0 and line.y1 then
            table.insert(lines, i)
        end
    end
    local pitches, sorted = {}, {}
    for n = 1, #lines - 1 do
        local pitch = boxes[lines[n + 1]].y0 - boxes[lines[n]].y0
        pitches[n] = pitch
        -- A step up or sideways is a new column, not a line step: it says
        -- nothing about the usual line spacing.
        if pitch > 0 then
            table.insert(sorted, pitch)
        end
    end
    table.sort(sorted)
    local usual_pitch = #sorted >= 3 and sorted[math.ceil(#sorted / 2)] or nil

    for n = 1, #lines - 1 do
        local cur, nxt = boxes[lines[n]], boxes[lines[n + 1]]
        local pitch = pitches[n]
        local h_cur, h_nxt = lineHeight(cur), lineHeight(nxt)
        local is_break = false
        if pitch > 0 then
            if usual_pitch then
                is_break = pitch > usual_pitch * PITCH_BREAK_RATIO
            elseif h_cur and h_cur > 0 then
                is_break = pitch > h_cur * LONE_PITCH_RATIO
            end
        end
        if not is_break and h_cur and h_nxt and h_cur > 0 and h_nxt > 0 then
            local taller, shorter = math.max(h_cur, h_nxt), math.min(h_cur, h_nxt)
            is_break = taller > shorter * HEIGHT_BREAK_RATIO
        end
        if is_break then
            breaks[lines[n]] = true
        end
    end
    return breaks
end

-- True if a block of text ends somewhere between line `i` and the later line
-- `ni` (i.e. stepping from a word on line `i` to a word on line `ni` leaves
-- the block the first word is in).
local function crossesBlockBreak(boxes, i, ni)
    if not ni or ni <= i then
        return false
    end
    local breaks = blockBreaks(boxes)
    for li = i, ni - 1 do
        if breaks[li] then
            return true
        end
    end
    return false
end

function PagingSegmenter:_buildUnit(pageno, boxes, i0, j0, i1, j1)
    local start_box = boxes[i0] and boxes[i0][j0]
    local end_box = boxes[i1] and boxes[i1][j1]
    if not start_box or not end_box then
        return nil
    end
    local pos0 = boxCenter(start_box)
    pos0.page = pageno
    local pos1 = boxCenter(end_box)
    pos1.page = pageno
    local text, line_boxes
    if i0 == i1 and j0 == j1 then
        text = start_box.word
        line_boxes = { { x = start_box.x0, y = boxes[i0].y0, w = start_box.x1 - start_box.x0, h = boxes[i0].y1 - boxes[i0].y0 } }
    else
        local koptinterface = self.ui.document.koptinterface
        local result = koptinterface:getTextFromBoxes(boxes, pos0, pos1)
        text = result.text
        line_boxes = result.boxes
    end
    return {
        page = pageno,
        i0 = i0, j0 = j0, i1 = i1, j1 = j1,
        pos0 = pos0, pos1 = pos1,
        text = text,
        boxes = line_boxes,
    }
end

-- Build a single-word unit at (i,j).
function PagingSegmenter:_wordUnit(pageno, boxes, i, j)
    return self:_buildUnit(pageno, boxes, i, j, i, j)
end

-- Extend forward from a word unit's end (i,j) until a terminal word is
-- found or the page ends; returns the sentence unit starting at (i0,j0).
function PagingSegmenter:_sentenceUnitFrom(pageno, boxes, i0, j0)
    local i, j = i0, j0
    while true do
        local word = boxes[i] and boxes[i][j] and boxes[i][j].word
        if word and SentenceRules.isTerminalWord(word) then
            return self:_buildUnit(pageno, boxes, i0, j0, i, j)
        end
        local ni, nj = stepForward(boxes, i, j)
        if not ni then
            -- Reached end of page without finding terminal punctuation;
            -- the sentence unit is just whatever we accumulated.
            return self:_buildUnit(pageno, boxes, i0, j0, i, j)
        end
        if crossesBlockBreak(boxes, i, ni) then
            -- The next word belongs to a different block of text (the
            -- paragraph under this heading, the next paragraph, ...): the
            -- sentence ends here, full stop or not.
            return self:_buildUnit(pageno, boxes, i0, j0, i, j)
        end
        i, j = ni, nj
    end
end

-- Walk backward from (i,j) to find the start of the sentence that contains
-- it: the word right after the previous terminal word (or page start).
function PagingSegmenter:_sentenceStartContaining(boxes, i, j)
    local ci, cj = i, j
    while true do
        local pi, pj = stepBackward(boxes, ci, cj)
        if not pi then
            return ci, cj -- walked back to the first word of the page
        end
        if crossesBlockBreak(boxes, pi, ci) then
            -- The previous word is in a different block of text (a heading
            -- above this paragraph, the previous paragraph, ...): the
            -- sentence starts here.
            return ci, cj
        end
        local word = boxes[pi][pj].word
        if word and SentenceRules.isTerminalWord(word) then
            -- The sentence starts at the word right after this terminal one.
            local si, sj = stepForward(boxes, pi, pj)
            return si or pi, sj or pj
        end
        ci, cj = pi, pj
    end
end

-- Current unit (word or sentence) at exact (i,j) index on `pageno`.
function PagingSegmenter:getUnitAt(pageno, i, j, granularity)
    local boxes = self:_getBoxes(pageno)
    if not boxes then
        return nil
    end
    if granularity == "sentence" then
        local si, sj = self:_sentenceStartContaining(boxes, i, j)
        return self:_sentenceUnitFrom(pageno, boxes, si, sj)
    else
        return self:_wordUnit(pageno, boxes, i, j)
    end
end

-- (line, word) index of the word box whose center is nearest to `pos`.
-- Same criterion as koptinterface's own nearest-box search, so a pos that
-- was itself produced from a box center resolves back to that exact box.
local function nearestWord(boxes, pos)
    local best_i, best_j, best_d
    for i, line in ipairs(boxes) do
        for j, box in ipairs(line) do
            local c = boxCenter(box)
            local d = (c.x - pos.x) ^ 2 + (c.y - pos.y) ^ 2
            if not best_d or d < best_d then
                best_i, best_j, best_d = i, j, d
            end
        end
    end
    return best_i, best_j
end

-- Rebuild a unit from an exact, previously saved pair of page positions (the
-- marker's own annotation item), WITHOUT re-deriving its boundaries from the
-- current granularity. Returns nil if the page has no text boxes.
function PagingSegmenter:getUnitFromPositions(pageno, pos0, pos1)
    if not pageno or type(pos0) ~= "table" or type(pos1) ~= "table"
        or not pos0.x or not pos0.y or not pos1.x or not pos1.y then
        return nil
    end
    local boxes = self:_getBoxes(pageno)
    if not boxes then
        return nil
    end
    local i0, j0 = nearestWord(boxes, pos0)
    local i1, j1 = nearestWord(boxes, pos1)
    if not i0 or not i1 then
        return nil
    end
    if i1 < i0 or (i1 == i0 and j1 < j0) then
        i0, j0, i1, j1 = i1, j1, i0, j0
    end
    return self:_buildUnit(pageno, boxes, i0, j0, i1, j1)
end

-- True if `unit` is on the page currently shown.
function PagingSegmenter:isUnitOnScreen(unit)
    if not unit or not unit.page then
        return false
    end
    return unit.page == self.ui:getCurrentPage()
end

function PagingSegmenter:getFirstUnitOnPage(pageno, granularity)
    local boxes = self:_getBoxes(pageno)
    if not boxes then
        return nil
    end
    local i, j = firstWordFrom(boxes, 1)
    if not i then
        return nil
    end
    if granularity == "sentence" then
        return self:_sentenceUnitFrom(pageno, boxes, i, j)
    else
        return self:_wordUnit(pageno, boxes, i, j)
    end
end

function PagingSegmenter:getLastUnitOnPage(pageno, granularity)
    local boxes = self:_getBoxes(pageno)
    if not boxes then
        return nil
    end
    local i, j = lastWordFrom(boxes, #boxes)
    if not i then
        return nil
    end
    if granularity == "sentence" then
        local si, sj = self:_sentenceStartContaining(boxes, i, j)
        return self:_sentenceUnitFrom(pageno, boxes, si, sj)
    else
        return self:_wordUnit(pageno, boxes, i, j)
    end
end

-- Move forward one unit. Returns nil (and leaves paging to the caller) when
-- the current page is exhausted.
function PagingSegmenter:nextUnit(unit, granularity)
    if not unit then
        return nil
    end
    local boxes = self:_getBoxes(unit.page)
    if not boxes then
        return nil
    end
    local ni, nj = stepForward(boxes, unit.i1, unit.j1)
    if not ni then
        return nil -- end of page
    end
    if granularity == "sentence" then
        return self:_sentenceUnitFrom(unit.page, boxes, ni, nj)
    else
        return self:_wordUnit(unit.page, boxes, ni, nj)
    end
end

-- Move backward one unit. Returns nil at start of page.
function PagingSegmenter:prevUnit(unit, granularity)
    if not unit then
        return nil
    end
    local boxes = self:_getBoxes(unit.page)
    if not boxes then
        return nil
    end
    local pi, pj = stepBackward(boxes, unit.i0, unit.j0)
    if not pi then
        return nil -- start of page
    end
    if granularity == "sentence" then
        local si, sj = self:_sentenceStartContaining(boxes, pi, pj)
        return self:_sentenceUnitFrom(unit.page, boxes, si, sj)
    else
        return self:_wordUnit(unit.page, boxes, pi, pj)
    end
end

-- Where the free space beside the text line `rect` (a screen rect of `unit`)
-- is on begins: the screen x of that line's first and last word. Found by
-- matching `rect` against the unit's own lines, transformed to the screen
-- the same way the highlight rects are.
function PagingSegmenter:getLineBounds(unit, rect)
    if not unit or not unit.page or not unit.i0 or not unit.i1 then
        return nil
    end
    local boxes = self:_getBoxes(unit.page)
    if not boxes then
        return nil
    end
    local view = self.ui.view
    local mid_y = rect.y + rect.h / 2
    for li = unit.i0, unit.i1 do
        local line = boxes[li]
        if line and line.x0 and line.x1 and line.y0 and line.y1 then
            local line_rect = view:pageToScreenTransform(unit.page, {
                x = line.x0, y = line.y0, w = line.x1 - line.x0, h = line.y1 - line.y0,
            })
            if line_rect and mid_y >= line_rect.y and mid_y <= line_rect.y + line_rect.h then
                return { left = line_rect.x, right = line_rect.x + line_rect.w }
            end
        end
    end
    return nil
end

-- Screen rects for a unit, if its page is currently visible; nil otherwise
-- (caller should fall back to not drawing / re-anchoring).
function PagingSegmenter:getScreenBoxes(unit)
    if not unit or not unit.boxes then
        return nil
    end
    local view = self.ui.view
    local screen_boxes = {}
    for _, box in ipairs(unit.boxes) do
        local rect = view:pageToScreenTransform(unit.page, box)
        if rect then
            table.insert(screen_boxes, rect)
        end
    end
    if #screen_boxes == 0 then
        return nil
    end
    return screen_boxes
end

return PagingSegmenter
