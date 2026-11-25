--[[--
A grid of tappable color swatches (rounded, filled rectangles), each with
its color's name in the middle. The current one is marked by a heavy border,
a bold name and a checkmark.

Shared by the marker popup (`ui/marker_popup.lua`, where a tap applies the
color immediately and the popup stays open) and the settings-menu color
picker (`ui/color_picker.lua`), so both always offer the same palette and
look the same.

    local grid = SwatchGrid.new{
        width = available_width,
        palette = Colors.PALETTE,     -- { { id, label, hex }, ... }
        current_id = "fl_gold",       -- may be nil / not in the palette
        columns = 4,                  -- default 4
        on_pick = function(id) end,   -- called after the selection moved
    }
    grid:setCurrent("fl_rose")        -- move the selection programmatically

The returned widget is a plain VerticalGroup; the caller owns repainting
(typically `UIManager:setDirty(dialog, "ui")` from `on_pick`).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Colors = require("lib/colors")

local SWATCH_H = Screen:scaleBySize(52)
local SWATCH_GAP = Screen:scaleBySize(12)
local SWATCH_RADIUS = Screen:scaleBySize(8)
local BORDER_IDLE = Size.border.thin
local BORDER_SELECTED = Screen:scaleBySize(3)

local LABEL_PADDING = Screen:scaleBySize(4) -- label to swatch border, each side
local LABEL_SIZES = { 16, 15, 14, 13, 12, 11, 10 } -- tried largest first
local CHECK = "\u{2713} "

-- The largest label font at which every name in `palette` fits a swatch
-- `max_w` wide, measured the way the selected swatch draws it (bold, with
-- the checkmark) so that picking a color never makes its name overflow.
-- One size for the whole grid, so the names line up as a set. If even the
-- smallest size is too wide, the names are truncated (see Swatch:_build).
local function fitLabelFace(palette, max_w)
    for _, size in ipairs(LABEL_SIZES) do
        local face = Font:getFace("cfont", size)
        local fits = true
        for _, entry in ipairs(palette) do
            local probe = TextWidget:new{ text = CHECK .. entry.label, face = face, bold = true }
            local w = probe:getSize().w
            probe:free()
            if w > max_w then
                fits = false
                break
            end
        end
        if fits then
            return face
        end
    end
    return Font:getFace("cfont", LABEL_SIZES[#LABEL_SIZES])
end

local Swatch = InputContainer:extend{
    color = nil, -- Blitbuffer color
    label = nil, -- the color's name, drawn in the middle of the swatch
    face = nil, -- label font
    width = nil,
    height = SWATCH_H,
    selected = false,
    callback = nil,
}

function Swatch:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self:_build()
    self.ges_events = {
        TapSwatch = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Swatch:_build()
    local border = self.selected and BORDER_SELECTED or BORDER_IDLE
    local text = self.label or ""
    if self.selected then
        text = CHECK .. text
    end
    local content
    if text ~= "" then
        content = TextWidget:new{
            text = text,
            face = self.face or Font:getFace("cfont", 14),
            bold = self.selected,
            -- Dark text on the pastel swatch. In night mode the screen is
            -- inverted, so "white" is what comes out dark.
            fgcolor = Screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            max_width = self.width - 2 * border - 2 * LABEL_PADDING,
        }
    else
        content = HorizontalSpan:new{ width = 0 }
    end
    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = border,
        color = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        radius = SWATCH_RADIUS,
        background = self.color,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - 2 * border, h = self.height - 2 * border },
            content,
        },
    }
end

function Swatch:setSelected(selected)
    selected = selected and true or false
    if selected == self.selected then
        return
    end
    self.selected = selected
    if self[1] then
        self[1]:free()
    end
    self:_build()
end

function Swatch:onTapSwatch()
    if self.callback then
        self.callback()
    end
    return true
end

local SwatchGrid = {}

function SwatchGrid.new(opts)
    local columns = opts.columns or 4
    local palette = opts.palette or Colors.PALETTE
    local swatch_w = math.floor((opts.width - SWATCH_GAP * (columns - 1)) / columns)
    local label_face = fitLabelFace(palette, swatch_w - 2 * BORDER_SELECTED - 2 * LABEL_PADDING)

    local grid = VerticalGroup:new{ align = "left" }
    local swatches = {}
    local row

    for i, entry in ipairs(palette) do
        if (i - 1) % columns == 0 then
            if row then
                table.insert(grid, VerticalSpan:new{ width = SWATCH_GAP })
            end
            row = HorizontalGroup:new{}
            table.insert(grid, row)
        else
            table.insert(row, HorizontalSpan:new{ width = SWATCH_GAP })
        end
        local swatch
        swatch = Swatch:new{
            color = Colors.swatchColor(entry),
            label = entry.label,
            face = label_face,
            width = swatch_w,
            selected = entry.id == opts.current_id,
            callback = function()
                for _, other in ipairs(swatches) do
                    other:setSelected(other == swatch)
                end
                if opts.on_pick then
                    opts.on_pick(entry.id)
                end
            end,
        }
        swatch.color_id = entry.id
        table.insert(swatches, swatch)
        table.insert(row, swatch)
    end

    function grid:setCurrent(id)
        for _, swatch in ipairs(swatches) do
            swatch:setSelected(swatch.color_id == id)
        end
    end

    return grid
end

return SwatchGrid
