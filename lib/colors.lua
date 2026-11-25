--[[--
Focusline's own marker color palette: eight soft pastel tones, chosen to sit
comfortably behind body text (unlike KOReader's stock highlight colors,
which are saturated "marker pen" hues).

How they reach the screen: every stock code path that paints a saved
highlight (readerview.lua's drawSavedHighlight, pdfdocument.lua's native
annotation writer, ...) turns `item.color` (a NAME, not a color value) into
a real color through `Blitbuffer.colorFromName`, which is a plain lookup in
the `Blitbuffer.HIGHLIGHT_COLORS` name -> "#RRGGBB" table. Registering our
names in that same table is therefore all it takes for the marker's
annotation item to keep carrying an ordinary color NAME (so it stays a
normal, saved, sidecar-serializable highlight) while rendering in a color
KOReader itself has never heard of - no second draw path, no per-call-site
patching.

The names are namespaced (`fl_*`) so they can never collide with a stock or
future KOReader color name, and lowercase because `colorFromName` lowercases
its argument before the lookup.

Stock color names ("yellow", "orange", ...) remain valid marker colors too:
a marker restyled through KOReader's own highlight dialogs (e.g. from the
bookmark list) keeps working and keeps its stock label.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local _ = require("gettext")

local Colors = {}

Colors.PALETTE = {
    { id = "fl_rose", label = _("Muted Rose"), hex = "#D9A0A3" },
    { id = "fl_sage", label = _("Sage"), hex = "#A5C9AC" },
    { id = "fl_apricot", label = _("Soft Apricot"), hex = "#D7B38F" },
    { id = "fl_blue", label = _("Dusty Blue"), hex = "#A4B6D6" },
    { id = "fl_gold", label = _("Muted Gold"), hex = "#D8CC91" },
    { id = "fl_lavender", label = _("Lavender"), hex = "#BCA9D3" },
    { id = "fl_cyan", label = _("Powder Cyan"), hex = "#9CCBD2" },
    { id = "fl_pink", label = _("Dusty Pink"), hex = "#D4AFC3" },
}

Colors.DEFAULT = "fl_gold"

local BY_ID = {}
for _, entry in ipairs(Colors.PALETTE) do
    BY_ID[entry.id] = entry
end

-- Idempotent; safe to call on every document open. Never overwrites an
-- existing entry, so a (hypothetical) future stock color of the same name
-- would win rather than being silently redefined.
function Colors.register()
    if not Blitbuffer.HIGHLIGHT_COLORS then
        return
    end
    for _, entry in ipairs(Colors.PALETTE) do
        if Blitbuffer.HIGHLIGHT_COLORS[entry.id] == nil then
            Blitbuffer.HIGHLIGHT_COLORS[entry.id] = entry.hex
        end
    end
end

function Colors.getById(id)
    return BY_ID[id]
end

-- Human-readable name for a marker color: our palette label, or - for a
-- stock color name - whatever ReaderHighlight calls it.
function Colors.getLabel(ui, color_name)
    local entry = BY_ID[color_name]
    if entry then
        return entry.label
    end
    if ui and ui.highlight and color_name then
        return ui.highlight:getHighlightColorString(color_name)
    end
    return color_name or "?"
end

-- The color a marker color NAME stands for, exactly as defined - the same
-- value KOReader hands to the highlight drawer. Use this (not
-- `ReaderHighlight:getHighlightColor`, which pre-inverts in night mode) for
-- anything painted by `lib/draw.lua`, which does its own night-mode handling.
function Colors.drawColor(color_name)
    return (color_name and Blitbuffer.colorFromName(color_name)) or Blitbuffer.COLOR_BLACK
end

-- The swatch color for a palette entry: a color chooser should show the
-- color being chosen. In night mode the whole screen is inverted, so the
-- color is pre-inverted to come out as itself rather than as its opposite
-- (a navy swatch standing for Muted Gold).
function Colors.swatchColor(entry)
    local color = Blitbuffer.colorFromString(entry.hex)
    if color and Screen.night_mode then
        return color:invert()
    end
    return color
end

Colors.register()

return Colors
