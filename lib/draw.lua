--[[--
Drawing: teaches `ReaderView:drawHighlightRect` how to paint focusline's own
composite look - a STYLE (box, border, pinned, the plain and ornament
underlines, or one of the stock underscore/strikeout/invert) with an
optional EDGE IMAGE (decorative PNG/SVG icon)
layered on top, independently of each other - while delegating every plain
stock style with no edge image to the original KOReader implementation
unchanged (so it renders and edits identically to a normal highlight,
including the stock highlight-edit dialog's live color swatches).

This is the single shared choke point `ReaderView:drawSavedHighlight`/
`drawTempHighlight` already funnel every highlight through (confirmed by
reading readerview.lua), so hooking it here means the live marker and any
normal repaint of the saved annotation render identically, with no second
code path to keep in sync.

Must be installed exactly once per KOReader process (monkey-patches the
`ReaderView` class, not an instance), guarded by `_focusline_patched`.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local ReaderView = require("apps/reader/modules/readerview")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Size = require("ui/size")
local logger = require("logger")
local util = require("util")

local Draw = {}

-- Fixed translucency for the "Box"/"Pinned" fill (0 = invisible, 1 =
-- opaque), independent of the stock "highlight_lighten_factor" setting so
-- switching stock highlight settings never silently changes the marker's
-- look.
local BOX_ALPHA = 0.3
local BOX_BORDER_THICK = Size.line.medium

-- "Pinned" style: a borderless tint (like Box, minus the border) with a
-- text-selection style handle at each end of the marked text - a vertical
-- bar capped with a round dot. The handle at the start has its dot on top,
-- the one at the end has its dot at the bottom.
local PIN_DOT_R = math.max(3, Screen:scaleBySize(3))
local PIN_LINE_THICK = Size.line.thick

-- Wavy/squiggly underline geometry. KOReader has no native wavy drawer (the
-- stock "underscore" is a straight line), so this hand-draws one as a
-- sine-like ripple of thickened pixel columns just under the baseline.
local WAVE_AMPLITUDE = 2 -- px, peak-to-center vertical travel
local WAVE_PERIOD = 10 -- px, one full ripple cycle
local WAVE_THICKNESS = math.max(1, Size.line.thick)

-- Other plain underlines: dashed/dotted/double. All are drawn just under the
-- baseline, like the stock "underscore".
local DASH_LEN = Screen:scaleBySize(6)
local DASH_GAP = Screen:scaleBySize(4)
local DOT_GAP = Screen:scaleBySize(5)
local DOT_R = math.max(1, Size.line.thick)
local DOUBLE_GAP = Screen:scaleBySize(2)

-- Ornament underlines: a thin line with a small drawing (ornaments/*.svg) in
-- the middle of it or at its ends, like a page divider.
--
-- Every ornament file is drawn 40 units tall with the line it belongs to
-- running through its vertical center, about 3 units thick. A "center"
-- ornament sits in the middle of the line. An "ends" ornament is drawn as
-- the piece for the START of the line (the line leaves it on the right) and
-- is mirrored for the end of the line.
local ORNAMENTS = {
    underline_diamond = { file = "ornaments/diamond.svg", place = "ends" },
    underline_flourish = { file = "ornaments/flourish.svg", place = "ends" },
    underline_leaves = { file = "ornaments/leaves.svg", place = "center" },
    underline_scroll = { file = "ornaments/scroll.svg", place = "center" },
    underline_flower = { file = "ornaments/flower.svg", place = "center" },
    underline_bow = { file = "ornaments/bow.svg", place = "center" },
    underline_quill = { file = "ornaments/quill.svg", place = "center" },
}
local ORNAMENT_H_RATIO = 0.5 -- ornament height, as a share of the text line's
local ORNAMENT_MIN_H = 7 -- px; smaller than this it is only a blot
local ORNAMENT_LINE_RATIO = 3 / 40 -- line thickness, as a share of the ornament's height

-- Set by Draw.install(): absolute path of the plugin folder, where the
-- ornament files are.
local plugin_dir

-- The color to hand to the blitter so a line comes out in `color` on screen.
-- In night mode the whole screen is inverted, and a color painted as-is would
-- be shown as its inverse (a gold box with a blue outline); KOReader's own
-- underline/strikeout drawers pre-invert colors for the same reason. Grays
-- are left alone: inverted, they still read as "a line on the page".
local function lineColor(color)
    if Screen.night_mode and not Blitbuffer.isColor8(color) then
        return color:invert()
    end
    return color
end

-- Paints a wavy underline spanning the full width of a highlight rect, one
-- pixel column at a time. `bb:setPixel` auto-converts `color` to whatever
-- pixel format the target blitbuffer actually uses (gray/RGB16/RGB24/RGB32,
-- see ffi/blitbuffer.lua's per-type `:set()`), so this needs no gray/color
-- branching unlike the rect-fill helpers below.
local function paintWavyUnderline(bb, x, y, w, h, color)
    color = lineColor(color)
    local baseline = y + h - WAVE_THICKNESS
    for ix = 0, w - 1 do
        local dy = math.floor(WAVE_AMPLITUDE * math.sin((ix / WAVE_PERIOD) * 2 * math.pi) + 0.5)
        local py = baseline + dy
        for t = 0, WAVE_THICKNESS - 1 do
            bb:setPixel(x + ix, py + t, color)
        end
    end
end

-- Tints a rect with `fill_color`, the text under it staying readable.
local function paintTint(bb, x, y, w, h, fill_color, is_gray, alpha)
    if is_gray then
        bb:darkenRect(x, y, w, h, alpha)
    elseif bb:getInverse() == 1 then
        -- Multiplying does nothing useful on night mode's black background;
        -- blend the (pre-inverted) color over it instead, as KOReader's own
        -- "lighten" drawer does.
        local c = Blitbuffer.ColorRGB32(fill_color.r, fill_color.g, fill_color.b, 0xFF * alpha):invert()
        bb:blendRectRGB32(x, y, w, h, c)
    else
        bb:multiplyRectRGB(x, y, w, h, fill_color)
    end
end

-- A rect-painting function bound to `bb`/`color` that picks the gray or
-- RGB32 blitter as appropriate - the same choice every style below needs to
-- make repeatedly for its various lines/dots/dashes.
local function rectPainter(bb, color, is_gray)
    if is_gray then
        return function(x, y, w, h) bb:paintRect(x, y, w, h, color) end
    end
    return function(x, y, w, h) bb:paintRectRGB32(x, y, w, h, color) end
end

local function circlePainter(bb, color)
    return function(cx, cy, r) bb:paintCircle(cx, cy, r, color) end
end

-- Paints the translucent-fill + border "Box" style.
local function paintBox(bb, x, y, w, h, fill_color, is_gray)
    paintTint(bb, x, y, w, h, fill_color, is_gray, BOX_ALPHA)
    local border_color = is_gray and Blitbuffer.COLOR_GRAY_2 or lineColor(fill_color)
    local paintLine = rectPainter(bb, border_color, is_gray)
    paintLine(x, y, w, BOX_BORDER_THICK)
    paintLine(x, y + h - BOX_BORDER_THICK, w, BOX_BORDER_THICK)
    paintLine(x, y, BOX_BORDER_THICK, h)
    paintLine(x + w - BOX_BORDER_THICK, y, BOX_BORDER_THICK, h)
end

-- Paints the "Border" style: Box's outline, with no fill at all - for a mark
-- that frames the text without tinting it.
local function paintBorder(bb, x, y, w, h, fill_color, is_gray)
    local border_color = is_gray and Blitbuffer.COLOR_GRAY_2 or lineColor(fill_color)
    local paintLine = rectPainter(bb, border_color, is_gray)
    paintLine(x, y, w, BOX_BORDER_THICK)
    paintLine(x, y + h - BOX_BORDER_THICK, w, BOX_BORDER_THICK)
    paintLine(x, y, BOX_BORDER_THICK, h)
    paintLine(x + w - BOX_BORDER_THICK, y, BOX_BORDER_THICK, h)
end

-- Paints the "Pinned" style: Box's tint with no border, plus a handle like
-- the ones at the ends of a text selection - a vertical bar with a round dot
-- - where the marked text starts (dot on top) and where it ends (dot at the
-- bottom). `is_first`/`is_last` say whether this rect is the first/last line
-- of the marked text: a sentence running over three lines gets one handle at
-- its very start and one at its very end, not a pair on every line.
local function paintPinned(bb, x, y, w, h, fill_color, is_gray, is_first, is_last)
    paintTint(bb, x, y, w, h, fill_color, is_gray, BOX_ALPHA)
    local line_color = is_gray and Blitbuffer.COLOR_GRAY_2 or lineColor(fill_color)
    local paintLine = rectPainter(bb, line_color, is_gray)
    local paintDot = circlePainter(bb, line_color)
    local bar_w = PIN_LINE_THICK
    local r = PIN_DOT_R

    if is_first then
        -- Just outside the rect, so the bar does not touch the first letter.
        local bar_x = x - bar_w
        paintLine(bar_x, y - r, bar_w, h + r)
        paintDot(bar_x + math.floor(bar_w / 2), y - r, r)
    end
    if is_last then
        local bar_x = x + w
        paintLine(bar_x, y, bar_w, h + r)
        paintDot(bar_x + math.floor(bar_w / 2), y + h + r, r)
    end
end

-- Paints a horizontal dashed line: ON for DASH_LEN px, OFF for DASH_GAP px,
-- repeating across the full width.
local function paintDashedLine(paintLine, x, y, w, thick)
    local ix = 0
    while ix < w do
        local seg = math.min(DASH_LEN, w - ix)
        paintLine(x + ix, y, seg, thick)
        ix = ix + DASH_LEN + DASH_GAP
    end
end

-- Paints a horizontal dotted line: one small filled circle every DOT_GAP px.
local function paintDottedLine(paintDot, x, y, w)
    local ix = DOT_R
    while ix < w do
        paintDot(x + ix, y, DOT_R)
        ix = ix + DOT_GAP
    end
end

-- Paints a horizontal double line: two thin parallel lines with a small gap
-- between them, both just under the baseline.
local function paintDoubleLine(paintLine, x, y, w, thick)
    paintLine(x, y - thick - DOUBLE_GAP, w, thick)
    paintLine(x, y, w, thick)
end

-- Ornaments ----------------------------------------------------------------

-- "file:height[:flipped]" -> 8-bit mask blitbuffer. Kept for the plugin's
-- lifetime: the masks are tiny, and rebuilding one means re-reading the SVG.
local ornament_masks = {}
local ornament_mask_count = 0
local ORNAMENT_MASK_LIMIT = 96

-- The line thickness that goes with an ornament `h` px tall.
local function ornamentLineThick(h)
    return math.max(1, math.floor(h * ORNAMENT_LINE_RATIO + 0.5))
end

-- The nearest height not above `h` at which an ornament's own line lands on
-- whole pixel rows, so that it meets the line painted beside it without a
-- half-pixel step: the ornament is centered on the line, so the two must be
-- both even or both odd in height.
local function ornamentHeight(h)
    while h > 1 and (h - ornamentLineThick(h)) % 2 ~= 0 do
        h = h - 1
    end
    return h
end

-- Renders an ornament `h` px tall into a mask: one byte per pixel, saying how
-- much of that pixel the drawing covers. That is the form the blitter tints
-- (it is how text is drawn in a color), so one black drawing can be painted
-- in whatever color the marker has. Returns nil if the file can't be drawn.
local function buildOrnamentMask(full_path, h, flipped)
    local src = RenderImage:renderSVGImageFile(full_path, nil, h)
    if not src then
        return nil
    end
    local sw, sh = src:getWidth(), src:getHeight()
    local mask = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
    for py = 0, sh - 1 do
        for px = 0, sw - 1 do
            local alpha = src:getPixel(px, py).alpha
            if alpha ~= 0 then
                mask:setPixel(flipped and (sw - 1 - px) or px, py, Blitbuffer.Color8(alpha))
            end
        end
    end
    src:free()
    return mask
end

local function getOrnamentMask(file, h, flipped)
    if not plugin_dir then
        return nil
    end
    local key = file .. ":" .. h .. (flipped and ":f" or "")
    local mask = ornament_masks[key]
    if mask ~= nil then
        return mask or nil -- `false` remembers a file that could not be drawn
    end
    if ornament_mask_count >= ORNAMENT_MASK_LIMIT then
        for _, old in pairs(ornament_masks) do
            if old then
                old:free()
            end
        end
        ornament_masks = {}
        ornament_mask_count = 0
    end
    local ok, res = pcall(buildOrnamentMask, plugin_dir .. "/" .. file, h, flipped)
    if not ok or not res then
        logger.warn("focusline: failed to load ornament", file, res)
        res = false
    end
    ornament_masks[key] = res
    ornament_mask_count = ornament_mask_count + 1
    return res or nil
end

-- The ornament at `want_h`, or at the largest smaller height at which it is
-- no wider than `max_w`. Returns nil when there is no room for it at a size
-- worth drawing (a short word): the caller then draws a plain line.
local function fitOrnamentMask(file, want_h, max_w)
    local h = ornamentHeight(want_h)
    for _ = 1, 4 do
        if h < ORNAMENT_MIN_H then
            return nil
        end
        local mask = getOrnamentMask(file, h)
        if not mask then
            return nil
        end
        local mw = mask:getWidth()
        if mw <= max_w then
            return mask
        end
        -- Too wide: shrink in proportion, and by at least one step.
        h = ornamentHeight(math.min(h - 1, math.floor(h * max_w / mw)))
    end
    return nil
end

-- Paints the mask in `color` with its top left corner at (x, y).
local function paintOrnamentMask(bb, mask, x, y, color, is_gray)
    if is_gray then
        bb:colorblitFrom(mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), color)
    else
        bb:colorblitFromRGB32(mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), color)
    end
end

-- Paints an ornament underline `w` px wide starting at `x`, the line running
-- along `axis_y`, the ornament `want_h` px tall where there is room for it.
-- `is_first`/`is_last`: whether this is the first/last line of the marked
-- text - an "ends" ornament goes where the text starts and where it ends, so
-- a sentence running over several lines reads as one long divider.
local function paintOrnamentLine(bb, x, axis_y, w, want_h, color, is_gray, is_first, is_last, spec)
    local paintLine = rectPainter(bb, color, is_gray)
    local function line(x0, x1, thick)
        if x1 > x0 then
            paintLine(x0, axis_y - math.floor(thick / 2), x1 - x0, thick)
        end
    end
    -- Where to put a mask so that its own line continues the painted one.
    local function maskTop(mask, thick)
        return axis_y - math.floor(thick / 2) - math.floor((mask:getHeight() - thick) / 2)
    end

    if spec.place == "center" then
        local mask = fitOrnamentMask(spec.file, want_h, w)
        if not mask then
            line(x, x + w, ornamentLineThick(want_h))
            return
        end
        local thick = ornamentLineThick(mask:getHeight())
        local mask_x = x + math.floor((w - mask:getWidth()) / 2)
        line(x, mask_x, thick)
        line(mask_x + mask:getWidth(), x + w, thick)
        paintOrnamentMask(bb, mask, mask_x, maskTop(mask, thick), color, is_gray)
        return
    end

    -- "ends": one piece where the text starts, its mirror image where it ends.
    local pieces = (is_first and 1 or 0) + (is_last and 1 or 0)
    if pieces == 0 then
        -- A line in the middle of the marked text: just the line.
        line(x, x + w, ornamentLineThick(ornamentHeight(want_h)))
        return
    end
    -- Sized on the unflipped piece, so that both ends get the same height.
    local sized = fitOrnamentMask(spec.file, want_h, math.floor(w / pieces))
    if not sized then
        line(x, x + w, ornamentLineThick(want_h))
        return
    end
    local piece_h = sized:getHeight()
    local thick = ornamentLineThick(piece_h)
    local line_x0, line_x1 = x, x + w
    if is_first then
        paintOrnamentMask(bb, sized, x, maskTop(sized, thick), color, is_gray)
        line_x0 = x + sized:getWidth()
    end
    if is_last then
        local mirrored = getOrnamentMask(spec.file, piece_h, true)
        if mirrored then
            line_x1 = x + w - mirrored:getWidth()
            paintOrnamentMask(bb, mirrored, line_x1, maskTop(mirrored, thick), color, is_gray)
        end
    end
    line(line_x0, line_x1, thick)
end

-- The plain underline kinds below share one shape: something drawn in a thin
-- band just under the baseline, same as the stock "underscore". Each has the
-- `(bb, x, y, w, h, fill_color, is_gray, is_first, is_last)` signature every
-- other style painter uses, so all of them can sit in one dispatch table
-- (see HAND_DRAWN_STYLES below) rather than needing their own special case
-- in both the live drawer and the picker preview.
local function paintUnderlineDashed(bb, x, y, w, h, fill_color, is_gray)
    local color = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(fill_color)
    local thick = Size.line.thick
    paintDashedLine(rectPainter(bb, color, is_gray), x, y + h - thick, w, thick)
end

local function paintUnderlineDotted(bb, x, y, w, h, fill_color, is_gray)
    local color = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(fill_color)
    paintDottedLine(circlePainter(bb, color), x, y + h - DOT_R - 1, w)
end

local function paintUnderlineDouble(bb, x, y, w, h, fill_color, is_gray)
    local color = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(fill_color)
    local thick = Size.line.medium
    paintDoubleLine(rectPainter(bb, color, is_gray), x, y + h - thick, w, thick)
end

-- A plain `(bb, x, y, w, h, fill_color, is_gray)` wrapper so the wavy
-- underline (whose own paintWavyUnderline() needs no is_gray branching, see
-- its comment) fits the same dispatch table as every other hand-drawn kind.
local function paintUnderlineWavyStyle(bb, x, y, w, h, fill_color, _is_gray)
    paintWavyUnderline(bb, x, y, w, h, fill_color)
end

-- A style painter for one ornament underline: the line runs where the stock
-- underline does, with the ornament centered on it.
local function ornamentPainter(spec)
    return function(bb, x, y, w, h, fill_color, is_gray, is_first, is_last)
        local color = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(fill_color)
        local want_h = math.floor(h * ORNAMENT_H_RATIO)
        paintOrnamentLine(bb, x, y + h - 1, w, want_h, color, is_gray, is_first, is_last, spec)
    end
end

-- Every focusline style kind that has no stock KOReader drawer, dispatched
-- by `style_kind` - shared by the live `drawHighlightRect` patch below and
-- by `Draw.paintStylePreview`, so the two can never visually diverge. Kinds
-- not listed here (underscore/strikeout/invert) delegate to KOReader's own
-- drawer instead (see Templates.STOCK_KINDS/resolve).
local HAND_DRAWN_STYLES = {
    box = paintBox,
    border = paintBorder,
    pinned = paintPinned,
    underline_wavy = paintUnderlineWavyStyle,
    underline_dashed = paintUnderlineDashed,
    underline_dotted = paintUnderlineDotted,
    underline_double = paintUnderlineDouble,
}
for kind, spec in pairs(ORNAMENTS) do
    HAND_DRAWN_STYLES[kind] = ornamentPainter(spec)
end

-- Style kinds that look different at the start and at the end of the marked
-- text, and so need to know which of its lines a rect is.
local ENDS_MATTER = { pinned = true }
for kind, spec in pairs(ORNAMENTS) do
    if spec.place == "ends" then
        ENDS_MATTER[kind] = true
    end
end

-- Whether `rect` is the first and/or the last line of the marker's text.
-- drawHighlightRect is handed one line at a time, with nothing to say which,
-- so the rect is looked up among the marker's own (in reading order).
-- Returns true, true when that can't be told, so that nothing goes missing.
local function rectEnds(marker, rect)
    if not marker then
        return true, true
    end
    local ok, boxes = pcall(marker.getCurrentBoxes, marker)
    if not ok or type(boxes) ~= "table" then
        return true, true
    end
    -- The two sets of rects come from the same text but not always from the
    -- same call, so they are matched by position rather than compared
    -- exactly: a box is `rect` if rect's center lies inside it.
    local cx, cy = rect.x + rect.w / 2, rect.y + rect.h / 2
    local function same(box)
        return cx >= box.x and cx <= box.x + box.w and cy >= box.y and cy <= box.y + box.h
    end
    local first, last, found
    for _, box in ipairs(boxes) do
        if box.h and box.h ~= 0 then
            first = first or box
            last = box
            found = found or same(box)
        end
    end
    if not found then
        return true, true
    end
    return same(first), same(last)
end

-- icon_relpath -> { [requested_h] = ImageWidget instance }, kept alive for
-- the plugin's lifetime; icons are tiny so this is cheap and avoids
-- re-decoding the SVG on every repaint while the marker sits still.
local icon_cache = {}

-- Renders the icon file to a blitbuffer exactly `h` pixels tall, keeping its
-- aspect ratio. Returns the blitbuffer and whether its alpha is "straight"
-- (NanoSVG) rather than premultiplied (MuPDF) - ImageWidget needs to know.
--
-- Done here rather than by handing ImageWidget the file plus a height:
-- ImageWidget caches a "scale to fit" file render under a key that does not
-- include the requested size, so every later request for the same icon got
-- back whichever size happened to be rendered first (the picker's preview
-- size, or a heading's line height reused on body text).
local function renderIcon(full_path, h)
    if util.getFileNameSuffix(full_path):lower() == "svg" then
        return RenderImage:renderSVGImageFile(full_path, nil, h)
    end
    local icon_bb = RenderImage:renderImageFile(full_path, false)
    if not icon_bb then
        return nil
    end
    local bw, bh = icon_bb:getWidth(), icon_bb:getHeight()
    if bh > 0 and bh ~= h then
        icon_bb = RenderImage:scaleBlitBuffer(icon_bb, math.max(1, math.floor(bw * h / bh + 0.5)), h, true)
    end
    return icon_bb, false
end

local function getIconWidget(plugin_root, icon_relpath, target_h)
    local h = math.max(8, math.floor(target_h))
    local by_size = icon_cache[icon_relpath]
    if not by_size then
        by_size = {}
        icon_cache[icon_relpath] = by_size
    end
    local widget = by_size[h]
    if widget then
        return widget
    end
    local full_path = plugin_root .. "/" .. icon_relpath
    local ok, w = pcall(function()
        local icon_bb, is_straight_alpha = renderIcon(full_path, h)
        if not icon_bb then
            return nil
        end
        local widget = ImageWidget:new{
            image = icon_bb,
            alpha = true,
            -- Like the text and the marker itself, the icon is inverted
            -- along with the page in night mode (a black icon turns white)
            -- instead of being kept as a dark shape in a white box.
            original_in_nightmode = false,
        }
        widget._is_straight_alpha = is_straight_alpha
        return widget
    end)
    if not ok or not w then
        logger.warn("focusline: failed to load icon", full_path, w)
        return nil
    end
    by_size[h] = w
    return w
end

local ICON_MIN = 8 -- px; below this an icon is an unreadable smudge
local ICON_GAP = BOX_BORDER_THICK + Size.padding.small -- icon to text, when there is room
local ICON_GAP_TIGHT = math.max(1, Size.border.thin) -- ... and when there is not

-- Loads the edge icon at `want_h`, shrunk if needed so it is no wider than
-- `max_w` (never below ICON_MIN). Returns the widget and its size.
local function fitIcon(plugin_root, icon_relpath, want_h, max_w)
    local icon = getIconWidget(plugin_root, icon_relpath, want_h)
    if not icon then
        return nil
    end
    local size = icon:getSize()
    if max_w and size.w > max_w and size.w > 0 then
        local fit_h = math.max(ICON_MIN, math.floor(want_h * max_w / size.w))
        if fit_h < want_h then
            icon = getIconWidget(plugin_root, icon_relpath, fit_h)
            if not icon then
                return nil
            end
            size = icon:getSize()
        end
    end
    return icon, size
end

-- Loads the edge icon for a strip of free space `room` px wide: full size
-- with the normal gap to the text if that fits, otherwise shrunk to what the
-- strip allows with a hairline gap. Returns widget, size, gap.
local function fitIconBeside(plugin_root, icon_relpath, want_h, room)
    local icon, size = fitIcon(plugin_root, icon_relpath, want_h)
    if not icon then
        return nil
    end
    if size.w + ICON_GAP <= room then
        return icon, size, ICON_GAP
    end
    -- Not enough room for the full-size icon: every pixel counts now, so
    -- give up the comfortable gap before giving up icon size.
    icon, size = fitIcon(plugin_root, icon_relpath, want_h, math.max(ICON_MIN, room - ICON_GAP_TIGHT))
    if not icon then
        return nil
    end
    return icon, size, ICON_GAP_TIGHT
end

-- Paints `template.edge_icon` beside the marked text - never on top of any
-- text, the marker's own or its neighbours'.
--
-- A left/right icon is a flag in the free space beside the LINE the rect is
-- on, not beside the rect itself: a marker usually starts or ends mid-line
-- (the second sentence of a paragraph, a single word), and an icon hung
-- directly off the rect would then sit on the words next to it. `bounds`
-- (`{left=, right=}`, screen x of where that free space begins on either
-- side, from `Marker:getLineBounds`) says where the line's text stops; the
-- icon is placed just outside it and shrunk to fit the room there is, so it
-- neither covers a letter nor is cut off by the edge of the screen. (With
-- narrow page margins that makes for a small icon: wider margins, or an
-- indented first line, give it room to be drawn at full size.)
local function paintEdgeIcon(bb, x, y, w, h, template, plugin_root, bounds)
    if not (template.edge_icon and plugin_root) then
        return
    end
    local icon_h = math.min(h, math.max(16, math.floor(h * 0.7)))
    local position = template.edge_position
    local icon, size, gap, icon_x, icon_y

    if position == "top" or position == "bottom" then
        icon, size = fitIcon(plugin_root, template.edge_icon, icon_h)
        if not icon then
            return
        end
        icon_x = x + math.floor((w - size.w) / 2)
        icon_y = position == "top" and (y - size.h - ICON_GAP) or (y + h + ICON_GAP)
    elseif position == "right" then
        local screen_w = bb:getWidth()
        local line_right = math.max(x + w, bounds and bounds.right or 0)
        icon, size, gap = fitIconBeside(plugin_root, template.edge_icon, icon_h, screen_w - line_right)
        if not icon then
            return
        end
        icon_x = math.min(line_right + gap, screen_w - size.w)
        icon_y = y + math.floor((h - size.h) / 2)
    else -- "left", default
        local line_left = math.min(x, bounds and bounds.left or x)
        icon, size, gap = fitIconBeside(plugin_root, template.edge_icon, icon_h, line_left)
        if not icon then
            return
        end
        icon_x = math.max(0, line_left - gap - size.w)
        icon_y = y + math.floor((h - size.h) / 2)
    end
    icon:paintTo(bb, icon_x, icon_y)
end

-- `fl` is the resolved focusline context needed at draw time:
--   fl.plugin_root            -- absolute path to focusline.koplugin/, for icons
--   fl:getCurrentTemplate()   -- returns the live marker's composite look
--                                ({style_kind, edge_icon, edge_position}), or
--                                nil. Only one annotation item ever carries
--                                the "focusline" drawer (the single marker),
--                                so drawHighlightRect never needs to know
--                                *which* item it's painting - there both
--                                stock call sites (drawPageSavedHighlight /
--                                drawXPointerSavedHighlight / drawTempHighlight)
--                                pass through unmodified, with no extra
--                                argument, and we just ask "what does the
--                                marker look like right now".
--
-- IMPORTANT: the ReaderView monkey-patch below is installed at most ONCE per
-- KOReader process (it patches the class, not an instance), but `fl` itself
-- must track the CURRENTLY OPEN document's plugin instance, which is a new
-- object every time a book is opened. So `Draw.install` is split in two:
-- updating `Draw._active` (cheap, happens on every document open) and the
-- actual one-time monkey-patch (guarded, happens once). The patched function
-- always reads `Draw._active`, never a closed-over `fl` from first install.
Draw._active = nil

function Draw.install(fl)
    Draw._active = fl
    plugin_dir = fl.plugin_root or plugin_dir
    if ReaderView._focusline_patched then
        return
    end
    ReaderView._focusline_patched = true
    local orig_drawHighlightRect = ReaderView.drawHighlightRect

    ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
        if drawer ~= "focusline" then
            return orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
        end

        local active = Draw._active
        local template = (active and active:getCurrentTemplate()) or { style_kind = "box" }
        local plugin_root = active and active.plugin_root

        local x, y, w, h = rect.x, rect.y, rect.w, rect.h
        local fill_color = color or Blitbuffer.COLOR_GRAY_4
        local is_gray = Blitbuffer.isColor8(fill_color)
        local style_kind = template.style_kind or "box"

        local painter = HAND_DRAWN_STYLES[style_kind]
        if painter then
            local is_first, is_last = true, true
            if ENDS_MATTER[style_kind] then
                is_first, is_last = rectEnds(active and active.marker, rect)
            end
            painter(bb, x, y, w, h, fill_color, is_gray, is_first, is_last)
            -- These have no stock equivalent, so replicate the stock tail of
            -- drawHighlightRect (note-mark indicators) via the pass-through
            -- hack: a drawer name the original function doesn't recognize
            -- paints nothing in its main body, only the note-mark tail.
            if self.highlight.note_mark ~= nil and draw_note_mark ~= nil then
                orig_drawHighlightRect(self, bb, _x, _y, rect, "__focusline_notemark_only__", color, draw_note_mark)
            end
        else
            -- style_kind is one of the real stock drawer names
            -- ("underscore"/"strikeout"/"invert"): delegate to the original
            -- function so the style itself (and its note-mark handling)
            -- renders byte-for-byte like a normal highlight; only the edge
            -- icon below is focusline's own addition.
            orig_drawHighlightRect(self, bb, _x, _y, rect, style_kind, color, draw_note_mark)
        end

        -- Edge icon overlay, independent of which style branch ran above -
        -- this is what lets ANY style carry a decorative edge image.
        if template.edge_icon then
            local bounds
            local marker = active and active.marker
            if marker then
                local ok, res = pcall(marker.getLineBounds, marker, rect)
                bounds = ok and res or nil
            end
            paintEdgeIcon(bb, x, y, w, h, template, plugin_root, bounds)
        end
    end
end

-- Standalone preview renderers, independent of any live ReaderView instance:
-- used by `ui/template_picker.lua`'s Style and Edge Image pickers to show
-- each entry's real look (not just a text label) without needing an open
-- document. The live drawer above and these previews share the same paint
-- helpers, so the picker's preview and the live marker never visually
-- diverge.

-- `style` is one of Templates.STYLES (has `.kind`).
function Draw.paintStylePreview(bb, x, y, w, h, style, color)
    color = color or Blitbuffer.COLOR_BLACK
    local is_gray = Blitbuffer.isColor8(color)
    local kind = style.kind

    local painter = HAND_DRAWN_STYLES[kind]
    if ORNAMENTS[kind] then
        -- On the page the ornament hangs on the line under the text; here
        -- there is no text, so it is shown on its own, in the middle.
        local c = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(color)
        paintOrnamentLine(bb, x, y + math.floor(h / 2), w, math.floor(h * 0.6), c, is_gray, true, true, ORNAMENTS[kind])
    elseif painter then
        if kind == "pinned" then
            -- Leave room for the handles, which stand outside the band.
            local inset_x = PIN_LINE_THICK + PIN_DOT_R
            local inset_y = 2 * PIN_DOT_R
            x, y, w, h = x + inset_x, y + inset_y, w - 2 * inset_x, h - 2 * inset_y
        end
        painter(bb, x, y, w, h, color, is_gray, true, true)
    elseif kind == "underscore" then
        local c = is_gray and Blitbuffer.COLOR_GRAY_4 or lineColor(color)
        if is_gray then
            bb:paintRect(x, y + h - Size.line.thick, w, Size.line.thick, c)
        else
            bb:paintRectRGB32(x, y + h - Size.line.thick, w, Size.line.thick, c)
        end
    elseif kind == "strikeout" then
        local c = is_gray and Blitbuffer.COLOR_BLACK or lineColor(color)
        local line_y = y + math.floor(h / 2)
        if is_gray then
            bb:paintRect(x, line_y, w, Size.line.medium, c)
        else
            bb:paintRectRGB32(x, line_y, w, Size.line.medium, c)
        end
    elseif kind == "invert" then
        bb:invertRect(x, y, w, h)
    else
        paintBox(bb, x, y, w, h, color, is_gray)
    end
end

-- `edge` is one of Templates.EDGE_IMAGES_BUILTIN/getEdgeImages() (has
-- `.edge_icon`). Draws just the icon, centered, with no underlying style -
-- the Edge Image picker previews the icon on its own, since it composes
-- onto whatever style is separately chosen.
function Draw.paintEdgeImagePreview(bb, x, y, w, h, edge, plugin_root)
    if not (edge and edge.edge_icon and plugin_root) then
        return
    end
    local icon_h = math.max(8, math.floor(h * 0.8))
    local icon = getIconWidget(plugin_root, edge.edge_icon, icon_h)
    if not icon then
        return
    end
    local size = icon:getSize()
    local icon_x = x + math.floor((w - size.w) / 2)
    local icon_y = y + math.floor((h - size.h) / 2)
    icon:paintTo(bb, icon_x, icon_y)
end

return Draw
