--[[--
Drawing: teaches `ReaderView:drawHighlightRect` how to paint focusline's own
composite look - a STYLE (box/lighten/underscore/strikeout/invert/
underline_wavy) with an optional EDGE IMAGE (decorative PNG/SVG icon)
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

-- Fixed translucency for the "Box" fill (0 = invisible, 1 = opaque),
-- independent of the stock "highlight_lighten_factor" setting so switching
-- stock highlight settings never silently changes the marker's look.
local BOX_ALPHA = 0.3
local BOX_BORDER_THICK = Size.line.medium

-- Wavy/squiggly underline geometry. KOReader has no native wavy drawer (the
-- stock "underscore" is a straight line), so this hand-draws one as a
-- sine-like ripple of thickened pixel columns just under the baseline.
local WAVE_AMPLITUDE = 2 -- px, peak-to-center vertical travel
local WAVE_PERIOD = 10 -- px, one full ripple cycle
local WAVE_THICKNESS = math.max(1, Size.line.thick)

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

-- Paints the translucent-fill + border "Box" style.
local function paintBox(bb, x, y, w, h, fill_color, is_gray)
    paintTint(bb, x, y, w, h, fill_color, is_gray, BOX_ALPHA)
    local border_color = is_gray and Blitbuffer.COLOR_GRAY_2 or lineColor(fill_color)
    local paintLine = is_gray
        and function(px, py, pw, ph) bb:paintRect(px, py, pw, ph, border_color) end
        or function(px, py, pw, ph) bb:paintRectRGB32(px, py, pw, ph, border_color) end
    paintLine(x, y, w, BOX_BORDER_THICK)
    paintLine(x, y + h - BOX_BORDER_THICK, w, BOX_BORDER_THICK)
    paintLine(x, y, BOX_BORDER_THICK, h)
    paintLine(x + w - BOX_BORDER_THICK, y, BOX_BORDER_THICK, h)
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

        if style_kind == "box" then
            paintBox(bb, x, y, w, h, fill_color, is_gray)
            -- Box has no stock equivalent, so replicate the stock tail of
            -- drawHighlightRect (note-mark indicators) via the pass-through
            -- hack: a drawer name the original function doesn't recognize
            -- paints nothing in its main body, only the note-mark tail.
            if self.highlight.note_mark ~= nil and draw_note_mark ~= nil then
                orig_drawHighlightRect(self, bb, _x, _y, rect, "__focusline_notemark_only__", color, draw_note_mark)
            end
        elseif style_kind == "underline_wavy" then
            paintWavyUnderline(bb, x, y, w, h, fill_color)
            if self.highlight.note_mark ~= nil and draw_note_mark ~= nil then
                orig_drawHighlightRect(self, bb, _x, _y, rect, "__focusline_notemark_only__", color, draw_note_mark)
            end
        else
            -- style_kind is one of the real stock drawer names
            -- ("lighten"/"underscore"/"strikeout"/"invert"): delegate to the
            -- original function so the style itself (and its note-mark
            -- handling) renders byte-for-byte like a normal highlight; only
            -- the edge icon below is focusline's own addition.
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

    if kind == "lighten" then
        paintTint(bb, x, y, w, h, color, is_gray, 0.2)
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
    elseif kind == "underline_wavy" then
        paintWavyUnderline(bb, x, y, w, h, color)
    else -- "box"
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
