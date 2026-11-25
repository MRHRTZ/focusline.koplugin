--[[--
The popup shown when the reader taps the Focusline marker, replacing
KOReader's stock highlight-edit dialog for that one annotation item.

    +------------------------------------------+
    | Marker Color                          X  |
    | [swatch] [swatch] [swatch] [swatch]      |
    | [swatch] [swatch] [swatch] [swatch]      |
    |------------------------------------------|
    |  Note   |  Style   |  Adjust  |  More    |
    +------------------------------------------+

  - Tapping a swatch applies that color IMMEDIATELY (no intermediate
    "Color" button, no second dialog) and leaves the popup open, so several
    colors can be tried in a row. It closes with the X or a tap outside.
  - Note   -> KOReader's own note editor for this item.
  - Style  -> Focusline's style picker.
  - Adjust -> a sub-dialog holding the four boundary-nudge buttons that sit
              in the second row of the stock dialog.
  - More   -> the rest of the stock dialog (delete, details, the stock
              highlight menu).

Every change goes through the plugin instance (`fl:onColorChanged`,
`fl:onStyleChanged`, `fl:adjustMarkerBoundary`), never by mutating the
annotation item directly - that is what keeps the settings menu, the
marker's own state and the saved annotation in agreement.

The marker's annotation index is re-resolved on every action
(`fl.bridge:getMarkerIndex()`) rather than captured once: auto-advance can
move the marker (delete + re-insert, i.e. a new index) while a dialog is
still open.
--]]--

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local IconButton = require("ui/widget/iconbutton")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local Screen = Device.screen
local _ = require("gettext")

local Colors = require("lib/colors")
local SwatchGrid = require("ui/swatch_grid")
local StylePicker = require("ui/template_picker").StylePicker

-- Nerd-font glyphs (nerdfonts/symbols.ttf is in KOReader's font fallback
-- chain; the stock highlight dialog uses the same trick for its trash can).
-- A Button shows either text or an icon, never both, hence glyph-in-text.
local GLYPH_NOTE = "\u{F040}" -- pencil
local GLYPH_STYLE = "\u{F1FC}" -- paint brush
local GLYPH_ADJUST = "\u{F07E}" -- horizontal arrows
local GLYPH_MORE = "\u{F142}" -- vertical ellipsis
local GLYPH_REMOVE = "\u{F48E}" -- trash can (same glyph as the stock dialog)
local GLYPH_BACK = "\u{F060}" -- left arrow

local CLOSE_ICON_SIZE = Screen:scaleBySize(22)
local CLOSE_ICON_PADDING = Screen:scaleBySize(6)

local MarkerPopup = {}

local function labelled(glyph, text)
    return glyph .. "  " .. text
end

-- Anchor a dialog just below (preferred) or above the marker, so the marker
-- itself stays visible while its color/boundaries are being changed. Falls
-- back to KOReader's default centering when the marker isn't on screen or
-- there is no room either side. Mirrors the "gesture" branch of
-- ReaderHighlight:_getDialogAnchor.
--
-- KOReader's "highlight dialog position" setting defaults to "center",
-- which would usually put the popup right on top of the marker; that
-- default is therefore not followed here. An explicit "top"/"bottom" choice
-- is honored.
local function makeAnchor(fl, get_dialog)
    return function()
        local dialog = get_dialog()
        local ui = fl.ui
        local index = fl.bridge:getMarkerIndex()
        if not dialog or not index then
            return
        end
        local position = G_reader_settings:readSetting("highlight_dialog_position")
        if position == "top" or position == "bottom" then
            return ui.highlight:_getDialogAnchor(dialog, index)
        end
        local boxes = ui.highlight:getHighlightVisibleBoxes(index)
        if not boxes then
            return
        end
        local box0, box1 = boxes[1], boxes[#boxes]
        if box0.y > box1.y then
            box0, box1 = box1, box0
        end
        if ui.paging then
            local page = ui.annotation.annotations[index].pos0.page
            box0 = ui.view:pageToScreenTransform(page, box0)
            box1 = ui.view:pageToScreenTransform(page, box1)
            if not box0 or not box1 then
                return
            end
        end
        local padding = Size.padding.small
        local y0 = box0.y
        local y1 = box1.y + box1.h
        local dialog_h = dialog:getContentSize().h + 2 * padding
        if y1 + dialog_h <= Screen:getHeight() then
            return { y = y1 + padding }, true -- pop down, below the marker
        elseif dialog_h <= y0 then
            return { y = y0 - padding } -- above the marker
        end
    end
end

-- "Marker Color" on the left, a close (X) icon on the right.
local function buildHeader(width, dialog, on_close)
    local close_button = IconButton:new{
        icon = "close",
        width = CLOSE_ICON_SIZE,
        height = CLOSE_ICON_SIZE,
        padding = CLOSE_ICON_PADDING,
        padding_right = 0,
        allow_flash = false,
        show_parent = dialog,
        callback = on_close,
    }
    local height = close_button:getSize().h
    local dimen = Geom:new{ w = width, h = height }
    return OverlapGroup:new{
        dimen = dimen:copy(),
        -- The two containers below already mirror themselves for RTL UIs;
        -- letting OverlapGroup mirror too would cancel that out.
        allow_mirroring = false,
        LeftContainer:new{
            dimen = dimen:copy(),
            TextWidget:new{
                text = _("Marker Color"),
                face = Font:getFace("x_smalltfont"),
                bold = true,
                max_width = width - close_button:getSize().w,
            },
        },
        RightContainer:new{
            dimen = dimen:copy(),
            close_button,
        },
    }
end

-- Main popup -------------------------------------------------------------

function MarkerPopup.show(fl)
    local ui = fl.ui
    local item = fl.bridge:getMarkerItem()
    if not item then
        return
    end

    local dialog
    local function close()
        UIManager:close(dialog)
    end

    dialog = ButtonDialog:new{
        name = "focusline_marker_popup",
        colorful = true,
        anchor = makeAnchor(fl, function() return dialog end),
        buttons = {
            {
                {
                    text = labelled(GLYPH_NOTE, _("Note")),
                    callback = function()
                        close()
                        local index = fl.bridge:getMarkerIndex()
                        if index then
                            ui.highlight:editNote(index)
                        end
                    end,
                },
                {
                    text = labelled(GLYPH_STYLE, _("Style")),
                    callback = function()
                        close()
                        StylePicker.show(fl.settings, {
                            current_style_id = fl.settings:getStyleId(),
                            color = Colors.drawColor(fl.settings:getColorName()),
                            on_pick = function(style)
                                fl:onStyleChanged(style)
                            end,
                        })
                    end,
                },
                {
                    text = labelled(GLYPH_ADJUST, _("Adjust")),
                    callback = function()
                        close()
                        MarkerPopup.showAdjust(fl)
                    end,
                },
                {
                    text = labelled(GLYPH_MORE, _("More")),
                    callback = function()
                        close()
                        MarkerPopup.showMore(fl)
                    end,
                },
            },
        },
    }

    local width = dialog:getAddedWidgetAvailableWidth()
    local content = VerticalGroup:new{
        align = "left",
        buildHeader(width, dialog, close),
        VerticalSpan:new{ width = Size.padding.default },
        SwatchGrid.new{
            width = width,
            palette = Colors.PALETTE,
            current_id = item.color,
            on_pick = function(color_id)
                fl:onColorChanged(color_id)
                UIManager:setDirty(dialog, "ui")
            end,
        },
        VerticalSpan:new{ width = Size.padding.default },
    }
    -- Keep ButtonDialog's key-focus layout to its own button row; the
    -- swatches are touch targets, not FocusManager items.
    content.not_focusable = true
    dialog:addWidget(content)
    UIManager:show(dialog)
    return dialog
end

-- "Adjust" sub-dialog ----------------------------------------------------
-- The four boundary-nudge buttons from the stock dialog's second row: move
-- the marker's start or end one word left/right. As in the stock dialog,
-- holding a button nudges by a single character instead and toggles that
-- mode for subsequent taps (rolling documents only - KOReader has no
-- per-character move for PDFs).

function MarkerPopup.showAdjust(fl)
    local item = fl.bridge:getMarkerItem()
    if not item then
        return
    end
    local enabled = not item.text_edited
    local start_prev, start_next, end_prev, end_next = "◁▒▒", "▷☓▒", "▒☓◁", "▒▒▷"
    if BD.mirroredUILayout() then
        start_prev, start_next = start_next, start_prev
        end_prev, end_next = end_next, end_prev
    end
    local move_by_char = false
    local dialog

    local function nudge(label, side, direction)
        return {
            text = label,
            enabled = enabled,
            callback = function()
                fl:adjustMarkerBoundary(side, direction, move_by_char)
            end,
            hold_callback = function()
                move_by_char = not move_by_char
                fl:adjustMarkerBoundary(side, direction, true)
            end,
        }
    end

    dialog = ButtonDialog:new{
        name = "focusline_marker_adjust",
        title = _("Adjust marker"),
        title_align = "center",
        anchor = makeAnchor(fl, function() return dialog end),
        buttons = {
            {
                nudge(start_prev, 0, -1),
                nudge(start_next, 0, 1),
                nudge(end_prev, 1, -1),
                nudge(end_next, 1, 1),
            },
            {
                {
                    text = labelled(GLYPH_BACK, _("Back")),
                    callback = function()
                        UIManager:close(dialog)
                        MarkerPopup.show(fl)
                    end,
                },
                {
                    text = _("Done"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

-- "More" sub-dialog ------------------------------------------------------

function MarkerPopup.showMore(fl)
    local ui = fl.ui
    if not fl.bridge:getMarkerItem() then
        return
    end
    local dialog
    local function close()
        UIManager:close(dialog)
    end

    dialog = ButtonDialog:new{
        name = "focusline_marker_more",
        anchor = makeAnchor(fl, function() return dialog end),
        buttons = {
            {
                {
                    text = labelled(GLYPH_REMOVE, _("Delete")),
                    callback = function()
                        close()
                        fl:removeMarker()
                    end,
                },
                {
                    text = _("Details"),
                    callback = function()
                        close()
                        local index = fl.bridge:getMarkerIndex()
                        if index then
                            ui.bookmark:showBookmarkDetails(index)
                        end
                    end,
                },
            },
            {
                {
                    -- The stock dialog's "…" button: copy, dictionary,
                    -- translate, search, etc. for the marked text.
                    text = _("Text actions…"),
                    callback = function()
                        close()
                        local index, item = fl.bridge:getMarkerIndex()
                        if index then
                            ui.highlight.selected_text = util.tableDeepCopy(item)
                            ui.highlight:onShowHighlightMenu(index)
                        end
                    end,
                },
                {
                    text = labelled(GLYPH_BACK, _("Back")),
                    callback = function()
                        close()
                        MarkerPopup.show(fl)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

return MarkerPopup
