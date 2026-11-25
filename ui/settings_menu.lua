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

local AUTO_ADVANCE_MODES = {
    {
        id = "manual",
        label = _("Manual: same time on every step"),
        help = _("The marker moves on after the interval you set below, whatever it is on."),
    },
    {
        id = "auto",
        label = _("Auto: time worked out from the text"),
        help = _("The marker stays on each sentence for as long as it takes to read it: the words in the sentence are counted, and the time is worked out from the reading speed you set below. A long sentence gets more time than a short one."),
    },
}

local autoAdvanceMsItem, autoAdvanceWpmItem

-- The "Auto-advance" sub-menu: the on/off switch, the two modes, and the one
-- number each mode uses.
local function autoAdvanceItems(fl)
    local items = {
        {
            text = _("Enable auto-advance"),
            checked_func = function() return fl.settings:isAutoAdvanceEnabled() end,
            callback = function()
                fl.settings:setAutoAdvanceEnabled(not fl.settings:isAutoAdvanceEnabled())
                fl:onAutoAdvanceSettingsChanged()
            end,
            separator = true,
        },
    }
    for _, mode in ipairs(AUTO_ADVANCE_MODES) do
        table.insert(items, {
            text = mode.label,
            radio = true,
            help_text = mode.help,
            checked_func = function()
                return fl.settings:getAutoAdvanceMode() == mode.id
            end,
            callback = function()
                fl.settings:setAutoAdvanceMode(mode.id)
                fl:onAutoAdvanceSettingsChanged()
            end,
        })
    end
    items[#items].separator = true
    table.insert(items, autoAdvanceMsItem(fl))
    table.insert(items, autoAdvanceWpmItem(fl))
    return items
end

function autoAdvanceWpmItem(fl)
    return {
        text_func = function()
            return T(_("Reading speed: %1 words per minute"), fl.settings:getAutoAdvanceWpm())
        end,
        keep_menu_open = true,
        enabled_func = function()
            return fl.settings:getAutoAdvanceMode() == "auto"
        end,
        callback = function(touchmenu_instance)
            local spin = SpinWidget:new{
                value = fl.settings:getAutoAdvanceWpm(),
                value_min = 30,
                value_max = 1000,
                value_step = 10,
                value_hold_step = 50,
                precision = "%d",
                unit = _("wpm"),
                ok_text = _("Set"),
                title_text = _("Reading speed"),
                info_text = _("How many words you read in a minute. Used in Auto mode to work out how long the marker stays on each sentence. Most people read between 150 and 300 words per minute."),
                callback = function(spin_widget)
                    fl.settings:setAutoAdvanceWpm(spin_widget.value)
                    fl:onAutoAdvanceSettingsChanged()
                    refreshMenu(touchmenu_instance)
                end,
            }
            UIManager:show(spin)
        end,
    }
end

function autoAdvanceMsItem(fl)
    return {
        text_func = function()
            return T(_("Interval: %1 ms"), fl.settings:getAutoAdvanceMs())
        end,
        keep_menu_open = true,
        enabled_func = function()
            return fl.settings:getAutoAdvanceMode() ~= "auto"
        end,
        callback = function(touchmenu_instance)
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
                info_text = _("How often the marker moves forward automatically, in milliseconds. Used in Manual mode. You can type an exact value."),
                callback = function(spin_widget)
                    fl.settings:setAutoAdvanceMs(spin_widget.value)
                    fl:onAutoAdvanceSettingsChanged()
                    refreshMenu(touchmenu_instance)
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
                text = _("Persistent marker"),
                checked_func = function() return settings:isPersistentMarkerEnabled() end,
                callback = function()
                    settings:setPersistentMarkerEnabled(not settings:isPersistentMarkerEnabled())
                end,
                help_text = _("When on, the marker stays on its page and its sentence while you turn pages yourself. Come back to that page and it is still there; press the button that moves the marker and you are taken back to it.\n\nWhen off, the marker follows you: it jumps to the top of every page you turn to."),
            },
            {
                text = _("Move marker to this page"),
                enabled_func = function() return settings:isEnabled() end,
                callback = function()
                    fl:onFocuslineMarkerHere()
                end,
                help_text = _("Puts the marker at the top of the page you are looking at."),
            },
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
                sub_item_table = autoAdvanceItems(fl),
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
