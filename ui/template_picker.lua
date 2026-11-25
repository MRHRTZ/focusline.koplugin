--[[--
Style picker and Edge Image picker: two scrollable lists, each row rendered
with a REAL live preview (via `lib/draw.lua`'s `Draw.paintStylePreview`/
`Draw.paintEdgeImagePreview`), not just a text label - so choosing a look
means seeing it, not guessing from a name.

These are deliberately two separate concepts/dialogs, not one combined
picker:
  - Style: how the marked text itself renders (box/lighten/underline/
    strikethrough/invert/wavy underline). Fixed catalog, not user-
    extensible - these are drawing algorithms, not assets. Exactly one is
    active.
  - Edge Image: an optional decorative PNG/SVG icon layered just outside the
    marked text, independent of (and composable with) whichever style is
    active. User-extensible - "Import PNG/SVG…" lives ONLY here.

Composed from scratch (custom row widget) rather than a stock `Menu`, since
`Menu`/`MenuItem` has no support for arbitrary pixel content inside a row
(confirmed by reading menu.lua) - only text + an optional "mandatory" string.

Entry points:
  StylePicker.show(settings, opts), opts:
      current_style_id (string)
      color_name        (string, e.g. "red") - used to render live previews
      on_pick(style)    -- called with the chosen style table
  EdgeImagePicker.show(settings, opts), opts:
      plugin_root
      current_edge_image_id (string)
      on_pick(edge_image) -- called with the chosen edge-image table
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local PathChooser = require("ui/widget/pathchooser")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen
local _ = require("gettext")
local T = ffiutil.template

local Draw = require("lib/draw")
local Templates = require("lib/templates")

local StylePicker = {}
local EdgeImagePicker = {}

local PREVIEW_W = Screen:scaleBySize(64)
local PREVIEW_H = Screen:scaleBySize(34)
local ROW_H = Screen:scaleBySize(56)
local ROW_PAD = Size.padding.default
local MAX_LIST_H = math.floor(Screen:getHeight() * 0.55)

-- Tiny standalone widget whose entire content is one entry's live preview.
-- `paint_fn(bb, x, y, w, h)` is supplied by the caller (style vs edge-image
-- preview use different lib/draw.lua routines/signatures).
local PreviewWidget = Widget:extend{
    paint_fn = nil,
    w = PREVIEW_W,
    h = PREVIEW_H,
}

function PreviewWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function PreviewWidget:paintTo(bb, x, y)
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    local ok, err = pcall(self.paint_fn, bb, x, y, self.w, self.h)
    if not ok then
        logger.warn("focusline: picker preview paint failed", err)
    end
end

-- One selectable row: [preview] [label]  (+ a checkmark if it's the current
-- entry). Tap picks it; hold offers rename/delete, but only when
-- `hold_callback` is supplied (user-imported edge images only).
local PickerRow = InputContainer:extend{
    paint_fn = nil,
    label = nil,
    width = nil,
    is_current = false,
    callback = nil,
    hold_callback = nil,
}

function PickerRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = ROW_H }

    local preview = PreviewWidget:new{
        paint_fn = self.paint_fn,
        w = PREVIEW_W,
        h = PREVIEW_H,
    }
    local label_text = self.label
    if self.is_current then
        label_text = "\u{2713} " .. label_text
    end
    local label = TextWidget:new{
        text = label_text,
        face = Font:getFace("cfont", 20),
        bold = self.is_current,
    }

    local hgroup = HorizontalGroup:new{
        HorizontalSpan:new{ width = ROW_PAD },
        preview,
        HorizontalSpan:new{ width = ROW_PAD * 2 },
        label,
    }

    self[1] = FrameContainer:new{
        width = self.width,
        height = ROW_H,
        padding = 0,
        margin = 0,
        bordersize = Size.border.thin,
        color = self.is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = ROW_H },
            hgroup,
        },
    }

    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function PickerRow:onTapSelect()
    if self.callback then
        self.callback()
    end
    return true
end

function PickerRow:onHoldSelect()
    if self.hold_callback then
        self.hold_callback()
    end
    return true
end

local function extIsImage(path)
    local lower = path:lower()
    return lower:match("%.png$") or lower:match("%.svg$")
end

local function rowWidth()
    return math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.86)
end

local function wrapRows(rows, row_width)
    local rows_size = rows:getSize()
    if rows_size.h > MAX_LIST_H then
        return ScrollableContainer:new{
            dimen = Geom:new{ w = row_width, h = MAX_LIST_H },
            show_parent = nil, -- set by caller once the dialog exists
            rows,
        }
    end
    return rows
end

-- Style picker ---------------------------------------------------------------
-- Fixed catalog (Templates.STYLES), never user-extensible - no import,
-- rename, or delete here.

function StylePicker.show(settings, opts)
    local color = opts.color or Blitbuffer.COLOR_BLACK
    local styles = Templates.getStyles()
    local row_width = rowWidth()

    local rows = VerticalGroup:new{ align = "left" }
    local dialog

    for _, style in ipairs(styles) do
        local is_current = style.id == opts.current_style_id
        local row = PickerRow:new{
            paint_fn = function(bb, x, y, w, h)
                Draw.paintStylePreview(bb, x, y, w, h, style, color)
            end,
            label = style.label,
            width = row_width,
            is_current = is_current,
            callback = function()
                if opts.on_pick then
                    opts.on_pick(style)
                end
                UIManager:close(dialog)
            end,
        }
        table.insert(rows, row)
        table.insert(rows, VerticalSpan:new{ width = Size.span.vertical_default })
    end

    local list_widget = wrapRows(rows, row_width)

    dialog = ButtonDialog:new{
        title = _("Marker style"),
        buttons = {
            {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    if list_widget.show_parent ~= nil then
        list_widget.show_parent = dialog
    end
    dialog:addWidget(list_widget)
    UIManager:show(dialog)
end

-- Edge image picker ----------------------------------------------------------
-- Built-ins + user-imported (Templates.getEdgeImages); only this picker
-- offers "Import PNG/SVG…", rename, and delete.

-- opts: plugin_root, current_edge_image_id, on_pick(edge_image)
function EdgeImagePicker.show(settings, opts)
    local plugin_root = opts.plugin_root
    local edge_images = Templates.getEdgeImages(settings)
    local row_width = rowWidth()

    local rows = VerticalGroup:new{ align = "left" }
    local dialog -- forward-declared, closed over by row callbacks

    local function refresh()
        UIManager:close(dialog)
        EdgeImagePicker.show(settings, opts)
    end

    local function offerDelete(edge_image)
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete edge image \"%1\"?\n\nThis only removes it from the picker; it does not undo any marker already using it (that marker keeps its current look until changed)."), edge_image.label),
            ok_text = _("Delete"),
            ok_callback = function()
                Templates.removeUserEdgeImage(settings, edge_image.id)
                if settings:getGlobal("edge_image_id") == edge_image.id then
                    settings:setEdgeImageId("edge_star")
                end
                refresh()
            end,
        })
    end

    local function offerRename(edge_image)
        local rename_dialog
        rename_dialog = InputDialog:new{
            title = _("Rename edge image"),
            input = edge_image.label,
            buttons = {
                {
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(rename_dialog) end },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local new_label = rename_dialog:getInputText()
                            UIManager:close(rename_dialog)
                            if new_label and new_label ~= "" then
                                Templates.renameUserEdgeImage(settings, edge_image.id, new_label)
                                refresh()
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(rename_dialog)
        rename_dialog:onShowKeyboard()
    end

    for _, edge_image in ipairs(edge_images) do
        local is_current = edge_image.id == opts.current_edge_image_id
        local row = PickerRow:new{
            paint_fn = function(bb, x, y, w, h)
                Draw.paintEdgeImagePreview(bb, x, y, w, h, edge_image, plugin_root)
            end,
            label = edge_image.label,
            width = row_width,
            is_current = is_current,
            callback = function()
                if opts.on_pick then
                    opts.on_pick(edge_image)
                end
                UIManager:close(dialog)
            end,
            hold_callback = edge_image.user_imported and function()
                local action_dialog
                action_dialog = ButtonDialog:new{
                    title = edge_image.label,
                    buttons = {
                        {
                            { text = _("Rename"), callback = function()
                                UIManager:close(action_dialog)
                                offerRename(edge_image)
                            end },
                            { text = _("Delete"), callback = function()
                                UIManager:close(action_dialog)
                                offerDelete(edge_image)
                            end },
                        },
                    },
                }
                UIManager:show(action_dialog)
            end or nil,
        }
        table.insert(rows, row)
        table.insert(rows, VerticalSpan:new{ width = Size.span.vertical_default })
    end

    local list_widget = wrapRows(rows, row_width)

    local function importIcon()
        local chooser
        chooser = PathChooser:new{
            title = _("Select a PNG or SVG icon to import"),
            select_file = true,
            select_directory = false,
            file_filter = extIsImage,
            onConfirm = function(path)
                local user_dir = plugin_root .. "/icons/user_imports"
                util.makePath(user_dir)
                local basename = path:match("([^/\\]+)$") or ("icon_" .. os.time())
                local dest = user_dir .. "/" .. basename
                local ok, err = pcall(ffiutil.copyFile, path, dest)
                if not ok then
                    logger.warn("focusline: icon import copy failed", err)
                    UIManager:show(InfoMessage:new{ text = _("Could not copy that file.") })
                    return
                end
                local relpath = "icons/user_imports/" .. basename
                local name_dialog
                name_dialog = InputDialog:new{
                    title = _("Name this edge image"),
                    input = basename:gsub("%.%w+$", ""),
                    buttons = {
                        {
                            { text = _("Cancel"), id = "close", callback = function() UIManager:close(name_dialog) end },
                            {
                                text = _("Add"),
                                is_enter_default = true,
                                callback = function()
                                    local label = name_dialog:getInputText()
                                    UIManager:close(name_dialog)
                                    if label and label ~= "" then
                                        Templates.addUserEdgeImage(settings, label, relpath, "left")
                                        refresh()
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(name_dialog)
                name_dialog:onShowKeyboard()
            end,
        }
        UIManager:show(chooser)
    end

    dialog = ButtonDialog:new{
        title = _("Marker edge image"),
        buttons = {
            {
                { text = _("Import PNG/SVG…"), callback = function()
                    UIManager:close(dialog)
                    importIcon()
                end },
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    if list_widget.show_parent ~= nil then
        list_widget.show_parent = dialog
    end
    dialog:addWidget(list_widget)
    UIManager:show(dialog)
end

return { StylePicker = StylePicker, EdgeImagePicker = EdgeImagePicker }
