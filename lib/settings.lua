--[[--
Global + per-document settings wrapper for focusline.

Global settings (template list, default granularity, auto-advance ms, etc.)
live in their own LuaSettings file under the KOReader settings dir
(`focusline_settings.lua`).

Per-document overrides (enabled state, granularity override, template
override, resume/auto-advance toggles) are stored inside the book's own
sidecar settings (`ui.doc_settings`) under the `"focusline"` key, so they are
saved/restored automatically with the rest of the document's settings and
need no bespoke persistence code.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Colors = require("lib/colors")

local GLOBAL_SETTINGS_FILE = DataStorage:getSettingsDir() .. "/focusline_settings.lua"

-- Stamped into the settings file; lets a later build tell which defaults a
-- file was first written with.
local SETTINGS_VERSION = 1

local GLOBAL_DEFAULTS = {
    granularity = "sentence", -- "word" | "sentence"
    style_id = "box",
    edge_image_enabled = false,
    edge_image_id = "edge_star",
    color_name = Colors.DEFAULT, -- a lib/colors.lua palette id, or a stock KOReader color name
    resume_enabled = true, -- "Jump to marker when reopening this book"
    auto_advance_enabled = false,
    auto_advance_ms = 4000,
    hijack_page_turn_keys = true, -- "Use page-turn buttons to move the marker"
    cycle_style_ids = { "box", "lighten", "underscore", "strikeout", "invert", "underline_wavy" },
    notification = true,
    edge_images = nil, -- user-imported edge images get appended here (see lib/templates.lua)
}

local DOC_DEFAULTS = {
    enabled = false,
    granularity = nil, -- nil = use global default
    style_id = nil, -- nil = use global default
    edge_image_id = nil, -- nil = use global default
    edge_image_enabled = nil, -- nil = use global default
    resume_enabled = nil, -- nil = use global default
    auto_advance_enabled = nil, -- nil = use global default
}

local Settings = {}
Settings.__index = Settings

function Settings:new(o)
    o = o or {}
    setmetatable(o, self)
    o.ui = o.ui
    o.global = LuaSettings:open(GLOBAL_SETTINGS_FILE)
    -- Builds before 0.1.0 wrote every default into the settings file on first
    -- run, with these two switched off. A `false` stored by such a build is
    -- that old default, not a choice the reader made, so it is brought up to
    -- the current default once. From then on the stored value is whatever
    -- the reader set in the menu.
    if o.global:readSetting("settings_version") == nil then
        o.global:saveSetting("resume_enabled", GLOBAL_DEFAULTS.resume_enabled)
        o.global:saveSetting("hijack_page_turn_keys", GLOBAL_DEFAULTS.hijack_page_turn_keys)
        o.global:saveSetting("settings_version", SETTINGS_VERSION)
    end
    for k, v in pairs(GLOBAL_DEFAULTS) do
        if o.global:readSetting(k) == nil then
            o.global:saveSetting(k, v)
        end
    end
    o.global:flush()
    return o
end

-- Global settings -----------------------------------------------------

function Settings:getGlobal(key)
    return self.global:readSetting(key)
end

function Settings:setGlobal(key, value)
    self.global:saveSetting(key, value)
    self.global:flush()
end

-- Per-document settings -------------------------------------------------

function Settings:_docTable()
    local doc_settings = self.ui.doc_settings
    local data = doc_settings:readSetting("focusline")
    if not data then
        data = {}
        doc_settings:saveSetting("focusline", data)
    end
    return data
end

function Settings:getDoc(key)
    local data = self:_docTable()
    local value = data[key]
    if value == nil then
        return DOC_DEFAULTS[key]
    end
    return value
end

function Settings:setDoc(key, value)
    local data = self:_docTable()
    data[key] = value
    -- doc_settings table is already the live reference; no explicit save call
    -- needed, it flushes along with the rest of the document's settings. We
    -- still nudge an explicit save on important/rare changes (handled by
    -- callers via self.ui.doc_settings:flush() where it matters, e.g. toggle).
end

-- Effective value: per-doc override, falling back to global default.

function Settings:isEnabled()
    return self:getDoc("enabled") == true
end

function Settings:setEnabled(value)
    self:setDoc("enabled", value and true or false)
end

function Settings:getGranularity()
    return self:getDoc("granularity") or self:getGlobal("granularity")
end

function Settings:setGranularity(value, doc_only)
    if doc_only then
        self:setDoc("granularity", value)
    else
        self:setGlobal("granularity", value)
    end
end

function Settings:getColorName()
    return self:getGlobal("color_name") or GLOBAL_DEFAULTS.color_name
end

function Settings:setColorName(value)
    self:setGlobal("color_name", value)
end

function Settings:getStyleId()
    return self:getDoc("style_id") or self:getGlobal("style_id")
end

function Settings:setStyleId(value, doc_only)
    if doc_only then
        self:setDoc("style_id", value)
    else
        self:setGlobal("style_id", value)
    end
end

function Settings:isEdgeImageEnabled()
    local doc_value = self:getDoc("edge_image_enabled")
    if doc_value ~= nil then
        return doc_value
    end
    return self:getGlobal("edge_image_enabled") == true
end

function Settings:setEdgeImageEnabled(value, doc_only)
    if doc_only then
        self:setDoc("edge_image_enabled", value and true or false)
    else
        self:setGlobal("edge_image_enabled", value and true or false)
    end
end

function Settings:getEdgeImageId()
    return self:getDoc("edge_image_id") or self:getGlobal("edge_image_id")
end

function Settings:setEdgeImageId(value, doc_only)
    if doc_only then
        self:setDoc("edge_image_id", value)
    else
        self:setGlobal("edge_image_id", value)
    end
end

function Settings:isResumeEnabled()
    local doc_value = self:getDoc("resume_enabled")
    if doc_value ~= nil then
        return doc_value
    end
    return self:getGlobal("resume_enabled") == true
end

function Settings:setResumeEnabled(value)
    self:setGlobal("resume_enabled", value and true or false)
end

function Settings:isAutoAdvanceEnabled()
    local doc_value = self:getDoc("auto_advance_enabled")
    if doc_value ~= nil then
        return doc_value
    end
    return self:getGlobal("auto_advance_enabled") == true
end

function Settings:setAutoAdvanceEnabled(value)
    self:setDoc("auto_advance_enabled", value and true or false)
end

function Settings:getAutoAdvanceMs()
    return self:getGlobal("auto_advance_ms") or GLOBAL_DEFAULTS.auto_advance_ms
end

function Settings:setAutoAdvanceMs(value)
    self:setGlobal("auto_advance_ms", value)
end

function Settings:getCycleStyleIds()
    return self:getGlobal("cycle_style_ids") or GLOBAL_DEFAULTS.cycle_style_ids
end

function Settings:setCycleStyleIds(ids)
    self:setGlobal("cycle_style_ids", ids)
end

function Settings:isNotificationEnabled()
    return self:getGlobal("notification") ~= false
end

function Settings:toggleNotification()
    self:setGlobal("notification", not self:isNotificationEnabled())
end

-- User-imported edge images (persisted globally, shared across books) ---

function Settings:getUserEdgeImages()
    return self.global:readSetting("edge_images") or {}
end

function Settings:setUserEdgeImages(list)
    self:setGlobal("edge_images", list)
end

return Settings
