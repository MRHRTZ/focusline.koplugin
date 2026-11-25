--[[--
Friendly "this document can't be marked" notice, shown instead of silently
no-opping (or crashing) when the user tries to enable focusline on a
document classified `"unsupported"` by `lib/capability.lua` (fixed-layout
docs with no extractable text layer - manga/comics/scanned images).
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local UnsupportedNotice = {}

function UnsupportedNotice.show()
    UIManager:show(InfoMessage:new{
        text = _([[
focusline needs a document with extractable text to know where words and sentences are.

This document appears to be image-only (e.g. a scanned page or a manga/comic without a text layer), so there's nothing for focusline to mark.

It works with:
• EPUB, FB2, MOBI, TXT, HTML and similar reflowable formats
• PDF and DJVU files that have a real text layer (including ones readable via OCR)

It does not work with image-only PDFs/DJVU, CBZ, or other picture-only formats.]]),
    })
end

return UnsupportedNotice
