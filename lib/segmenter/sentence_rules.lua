--[[--
Shared sentence-boundary heuristics, used by both segmenters:
`isTerminalWord` by the paging segmenter, whose "words" (from
`document:getTextBoxes`) keep their attached punctuation; `isTerminalGap` by
the rolling segmenter, whose crengine word walk strips punctuation out of
every word's own text, leaving it only in the gap between words (see the
rolling segmenter's own comments for why `extendXPointersToSentenceSegment`
isn't used instead).

A "terminal" word is one that plausibly ends a sentence: it ends with one of
`. ! ? …` (optionally followed by a closing quote/parenthesis), is not a
common abbreviation, and is not a decimal number or an initial.

Punctuation is not the only thing that ends a sentence: so does the end of
the block of text it is in (see `isBlockBreak` for rolling documents; the
paging segmenter has its own geometric equivalent).
--]]--

local SentenceRules = {}

-- Common abbreviations that end with a period but do not end a sentence.
-- Lower-cased, without the trailing period, for case-insensitive matching.
SentenceRules.ABBREVIATIONS = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
    "e.g", "i.e", "fig", "figs", "vol", "vols", "no", "nos", "pp", "p",
    "approx", "apt", "dept", "est", "inc", "ltd", "co", "corp", "ave", "blvd",
    "rd", "ft", "gen", "rev", "capt", "col", "cmdr", "lt", "maj", "sgt",
    "al", -- "et al."
}

local ABBREV_SET = {}
for _, w in ipairs(SentenceRules.ABBREVIATIONS) do
    ABBREV_SET[w] = true
end

local TERMINAL_CHARS = {
    ["."] = true, ["!"] = true, ["?"] = true, ["\u{2026}"] = true, -- …
}

local CLOSERS = {
    ["\""] = true, ["'"] = true, [")"] = true, ["]"] = true, ["\u{201D}"] = true,
    ["\u{2019}"] = true,
}

-- Strip trailing closing quotes/parens to look at the actual terminal char.
local function stripClosers(word)
    local i = #word
    while i > 0 do
        local c = word:sub(i, i)
        if CLOSERS[c] then
            i = i - 1
        else
            break
        end
    end
    return word:sub(1, i), word:sub(i + 1)
end

-- Returns true if `word` (the plain text of a word, punctuation included)
-- plausibly ends a sentence.
function SentenceRules.isTerminalWord(word)
    if not word or word == "" then
        return false
    end
    local core, _trailing = stripClosers(word)
    if core == "" then
        return false
    end
    local last = core:sub(-1)
    if not TERMINAL_CHARS[last] then
        return false
    end
    -- Ellipsis always counts, regardless of what precedes it.
    if last == "\u{2026}" then
        return true
    end
    -- Decimal numbers like "3.14" shouldn't terminate on the embedded dot;
    -- but here `core` ends with the char itself, so check if this is a
    -- mid-number dot followed immediately by more digits is impossible
    -- (the word already ends there) - instead guard against a *trailing*
    -- single dot after digits with nothing else, which is a common page/
    -- section reference like "3." - treat as non-terminal only if it's a
    -- bare number (no sentence-casing context available, so this is a
    -- best-effort heuristic).
    local before_punct = core:sub(1, -2)
    if last == "." then
        if before_punct:match("^%d+$") then
            -- Pure numeral followed by a dot ("12.") - likely a list/heading
            -- marker, not a sentence end.
            return false
        end
        -- Abbreviation guard: last "word" before the dot (case-insensitive,
        -- strip any leading punctuation).
        local bare = before_punct:match("([%a]+)$")
        if bare and ABBREV_SET[bare:lower()] then
            return false
        end
        -- Single-letter initial, e.g. "J." in "J. R. R. Tolkien".
        if before_punct:match("^%a$") then
            return false
        end
    end
    return true
end

-- A sentence never continues from one block of text into the next: a heading
-- is not the start of the paragraph under it, a list item is not the start of
-- the next list item - whether or not the block happens to end with a full
-- stop (headings, titles, captions and list items usually don't).
--
-- In a rolling document, the text spanning two consecutive words that sit in
-- different blocks (heading/paragraph/list item/table cell/...) contains a
-- newline: crengine inserts one between block elements when it extracts
-- text, and otherwise never produces one outside preformatted text (line
-- breaks in the book's source are collapsed to spaces when it is parsed). An
-- explicit line break (<br>, a line of verse or code) also yields one, and is
-- treated the same way.
--
-- `span` must run from the START of the first word to the END of the second:
-- the text of only the gap between them comes back empty when the first word
-- ends its block and the second starts the next one.
function SentenceRules.isBlockBreak(span)
    if not span or span == "" then
        return false
    end
    return span:find("[\r\n]") ~= nil
end

-- Rolling (crengine) documents' word walk (`getNextVisibleWordStart`/
-- `getNextVisibleWordEnd`) returns word text with punctuation stripped out
-- entirely - "dog." yields a word whose text is just "dog"; the period
-- lives only in the (otherwise whitespace) gap between that word's end and
-- the next word's start. `isTerminalWord` above is for the paging segmenter,
-- where a "word" (from `getTextBoxes`) keeps its attached punctuation; this
-- is the equivalent check for that gap text instead, given the word
-- immediately before it (for the abbreviation/initial/numeral guards, which
-- need to look at what precedes the punctuation).
function SentenceRules.isTerminalGap(gap, prev_word)
    if not gap or gap == "" then
        return false
    end
    local found
    for i = 1, #gap do
        local c = gap:sub(i, i)
        if TERMINAL_CHARS[c] then
            found = c
            break
        end
    end
    if not found then
        return false
    end
    -- Ellipsis always counts, regardless of what precedes it.
    if found == "\u{2026}" then
        return true
    end
    if found == "." then
        if not prev_word or prev_word == "" then
            return true
        end
        if prev_word:match("^%d+$") then
            -- Pure numeral followed by a dot ("12." or "3.14") - likely a
            -- list/section marker or a decimal number, not a sentence end.
            return false
        end
        local bare = prev_word:match("([%a]+)$")
        if bare and ABBREV_SET[bare:lower()] then
            return false
        end
        -- Single-letter initial, e.g. "J." in "J. R. R. Tolkien".
        if prev_word:match("^%a$") then
            return false
        end
    end
    return true
end

return SentenceRules
