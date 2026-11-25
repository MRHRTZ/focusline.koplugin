--[[--
Color picker for the settings menu's "Color" entry: the same swatch grid
(`ui/swatch_grid.lua`) over the same palette (`lib/colors.lua`) as the
popup shown when tapping the marker (`ui/marker_popup.lua`), so the two
always agree on which colors exist and what they look like.

Tapping a swatch applies it and closes the picker.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Colors = require("lib/colors")
local SwatchGrid = require("ui/swatch_grid")

local ColorPicker = {}

-- current_color_name: the active color id (e.g. "fl_gold"); may be a stock
--                     KOReader color name, in which case no swatch is marked.
-- on_pick(color_name): called with the chosen palette id.
function ColorPicker.show(current_color_name, on_pick)
    local dialog
    dialog = ButtonDialog:new{
        title = _("Marker color"),
        colorful = true,
        buttons = {
            {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    local grid = SwatchGrid.new{
        width = dialog:getAddedWidgetAvailableWidth(),
        palette = Colors.PALETTE,
        current_id = current_color_name,
        on_pick = function(color_id)
            UIManager:close(dialog)
            if on_pick then
                on_pick(color_id)
            end
        end,
    }
    grid.not_focusable = true
    dialog:addWidget(grid)
    UIManager:show(dialog)
    return dialog
end

return ColorPicker
