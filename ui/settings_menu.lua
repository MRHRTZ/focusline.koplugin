--[[--
Builds focusline's `addToMainMenu` sub-menu table. Kept separate from
`main.lua` purely to keep that file focused on wiring/events; this module
is pure UI composition, calling back into the plugin instance (`fl`) for
every actual state change.

`fl` is the live focusline plugin instance (main.lua's `self`), expected to
expose: settings, marker, bridge, autoadvance, capability, templates
resolution helpers (getCurrentTemplate), and the action methods used below
(onToggleEnabled, refreshMarkerStyle, etc.) - see main.lua for the exact
surface.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local _ = require("gettext")
local T = ffiutil.template

local ColorPicker = require("ui/color_picker")
local Colors = require("lib/colors")
local Pickers = require("ui/template_picker")
local StylePicker = Pickers.StylePicker
local EdgeImagePicker = Pickers.EdgeImagePicker
local Templates = require("lib/templates")

local SettingsMenu = {}

-- The "Style: %1" / "Edge image: %1" / "Color: %1" rows are text_funcs, but
-- TouchMenu only re-evaluates them when it rebuilds its item list. A picker
-- opened from one of those rows closes on top of a menu that is still
-- showing the OLD label, so ask the menu to rebuild once the pick is applied.
local function refreshMenu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

local GRANULARITIES = {
    { id = "word", label = _("Word") },
    { id = "sentence", label = _("Sentence") },
}

local function granularitySubItems(fl)
    local items = {}
    for _, g in ipairs(GRANULARITIES) do
        table.insert(items, {
            text = g.label,
            radio = true,
            checked_func = function()
                return fl.settings:getGranularity() == g.id
            end,
            callback = function()
                fl:onSetGranularity(g.id)
            end,
        })
    end
    return items
end

local function autoAdvanceMsItem(fl)
    return {
        text_func = function()
            return T(_("Auto-advance interval: %1 ms"), fl.settings:getAutoAdvanceMs())
        end,
        keep_menu_open = true,
        enabled_func = function()
            return fl.settings:isAutoAdvanceEnabled()
        end,
        callback = function()
            local spin = SpinWidget:new{
                value = fl.settings:getAutoAdvanceMs(),
                value_min = 200,
                value_max = 120000,
                value_step = 100,
                value_hold_step = 1000,
                precision = "%d",
                unit = _("ms"),
                ok_text = _("Set"),
                title_text = _("Auto-advance interval"),
                info_text = _("How often the marker moves forward automatically, in milliseconds. You can type an exact value."),
                callback = function(spin_widget)
                    fl.settings:setAutoAdvanceMs(spin_widget.value)
                    fl:onAutoAdvanceSettingsChanged()
                end,
            }
            UIManager:show(spin)
        end,
    }
end

local function cycleStyleInfo(fl)
    return {
        text = _("Quick-style cycle includes"),
        keep_menu_open = true,
        callback = function()
            local dialog
            local all = Templates.getStyles()
            local current_ids = {}
            for _, id in ipairs(fl.settings:getCycleStyleIds()) do
                current_ids[id] = true
            end
            local buttons = {}
            for _, t in ipairs(all) do
                table.insert(buttons, {
                    {
                        text = (current_ids[t.id] and "\u{2611} " or "\u{2610} ") .. t.label,
                        callback = function()
                            local ids = fl.settings:getCycleStyleIds()
                            local found = false
                            for i, id in ipairs(ids) do
                                if id == t.id then
                                    table.remove(ids, i)
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(ids, t.id)
                            end
                            fl.settings:setCycleStyleIds(ids)
                            UIManager:close(dialog)
                            cycleStyleInfo(fl).callback()
                        end,
                    },
                })
            end
            table.insert(buttons, {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            })
            dialog = ButtonDialog:new{
                title = _("Styles the quick-style action cycles through (tap to toggle)"),
                buttons = buttons,
            }
            UIManager:show(dialog)
        end,
    }
end

function SettingsMenu.build(fl)
    local settings = fl.settings

    return {
        -- Without an explicit sorting_hint, KOReader's MenuSorter treats an
        -- unreferenced top-level menu_items key as an "orphan": it gets a
        -- "NEW: " prefix and is silently appended to the first page of the
        -- *first* top-level menu button (confirmed by reading
        -- frontend/ui/menusorter.lua). That made Focusline hard to find and
        -- gave it an ugly, temporary-looking label. Pin it explicitly next
        -- to the other highlight-related settings instead.
        sorting_hint = "typeset",
        text = _("Focusline reading marker"),
        sub_item_table = {
            {
                text = _("Enable for this book"),
                checked_func = function() return settings:isEnabled() end,
                callback = function()
                    fl:onToggleEnabled()
                end,
            },
            {
                text = _("Granularity"),
                sub_item_table = granularitySubItems(fl),
                separator = true,
            },
            {
                text_func = function()
                    local s = Templates.getStyleById(settings:getStyleId())
                    return T(_("Style: %1"), s and s.label or "?")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    StylePicker.show(settings, {
                        current_style_id = settings:getStyleId(),
                        color = Colors.drawColor(settings:getColorName()),
                        on_pick = function(style)
                            fl:onStyleChanged(style)
                            refreshMenu(touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                text = _("Edge image (decorative icon)"),
                checked_func = function() return settings:isEdgeImageEnabled() end,
                callback = function()
                    fl:onEdgeImageEnabledToggled()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local e = Templates.getEdgeImageById(settings, settings:getEdgeImageId())
                    return T(_("Edge image: %1"), e and e.label or "?")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    EdgeImagePicker.show(settings, {
                        plugin_root = fl.plugin_root,
                        current_edge_image_id = settings:getEdgeImageId(),
                        on_pick = function(edge_image)
                            fl:onEdgeImageChanged(edge_image)
                            refreshMenu(touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Color: %1"), Colors.getLabel(fl.ui, settings:getColorName()))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    ColorPicker.show(settings:getColorName(), function(color_name)
                        fl:onColorChanged(color_name)
                        refreshMenu(touchmenu_instance)
                    end)
                end,
                separator = true,
            },
            cycleStyleInfo(fl),
            {
                text = _("Jump to marker when reopening this book"),
                checked_func = function() return settings:isResumeEnabled() end,
                callback = function()
                    settings:setResumeEnabled(not settings:isResumeEnabled())
                end,
                separator = true,
            },
            {
                text = _("Auto-advance"),
                sub_item_table = {
                    {
                        text = _("Enable auto-advance"),
                        checked_func = function() return settings:isAutoAdvanceEnabled() end,
                        callback = function()
                            settings:setAutoAdvanceEnabled(not settings:isAutoAdvanceEnabled())
                            fl:onAutoAdvanceSettingsChanged()
                        end,
                    },
                    autoAdvanceMsItem(fl),
                },
                separator = true,
            },
            {
                text = _("Keyboard / page-turn button bindings"),
                sub_item_table = {
                    {
                        text = _("Use page-turn buttons to move the marker"),
                        checked_func = function() return settings:getGlobal("hijack_page_turn_keys") == true end,
                        callback = function()
                            local cur = settings:getGlobal("hijack_page_turn_keys") == true
                            settings:setGlobal("hijack_page_turn_keys", not cur)
                            fl:onKeyBindingSettingsChanged()
                        end,
                        help_text = _("When enabled, a single tap of the next/previous page button moves the marker by one unit; the button only turns the real page once the marker reaches the edge of the screen. Also available via Dispatcher/gesture actions regardless of this setting."),
                    },
                },
                separator = true,
            },
            {
                text = _("Notify on auto-advance pause"),
                checked_func = function() return settings:isNotificationEnabled() end,
                callback = function()
                    settings:toggleNotification()
                end,
            },
        },
    }
end

return SettingsMenu
