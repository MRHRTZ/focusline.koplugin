--[[--
focusline: marks the reader's current reading position (word-by-word or
sentence-by-sentence) with a customizable highlight that moves as you read.

This file is pure wiring: it owns the plugin lifecycle (init/menu/dispatcher/
events) and delegates all real logic to lib/*.lua, all UI composition to
ui/*.lua.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local T = require("ffi/util").template
local _ = require("gettext")

local AnnotationBridge = require("lib/annotation_bridge")
local AutoAdvance = require("lib/autoadvance")
local Capability = require("lib/capability")
local Colors = require("lib/colors")
local Draw = require("lib/draw")
local Marker = require("lib/marker")
local Resume = require("lib/resume")
local Settings = require("lib/settings")
local Templates = require("lib/templates")
local MarkerPopup = require("ui/marker_popup")
local SettingsMenu = require("ui/settings_menu")
local UnsupportedNotice = require("ui/unsupported_notice")

local Focusline = InputContainer:extend{
    name = "focusline",
    is_doc_only = true,
}

-- Which key_events entry (owned by ReaderPaging/ReaderRolling, NOT us) drives
-- the next/prev page-turn buttons for each document kind. We redirect these
-- in place rather than adding our own key_events, because ReaderUI propagates
-- key presses to its registered modules in REGISTRATION order and stops at
-- the first handler that returns true - paging/rolling are registered long
-- before plugins are loaded, so a sibling key_events table of our own would
-- never even be consulted (confirmed by reading readerui.lua/inputcontainer.lua).
local NEXT_KEY_NAME = { paging = "GotoNextPage", rolling = "GotoNextView" }
local PREV_KEY_NAME = { paging = "GotoPrevPage", rolling = "GotoPrevView" }

-- Lifecycle ---------------------------------------------------------------

function Focusline:init()
    self.plugin_root = self.path -- set by PluginLoader before :new() is called
    self.settings = Settings:new{ ui = self.ui }
    self.capability = Capability:new{ ui = self.ui }
    self.bridge = AnnotationBridge:new{ ui = self.ui, view = self.view }
    -- resume.marker is filled in once self:_ensureMarker() has run (see
    -- onReaderReady/onToggleEnabled); lib/resume.lua needs a live Marker
    -- instance to anchor to the saved position.
    self.resume = Resume:new{
        ui = self.ui,
        settings = self.settings,
        bridge = self.bridge,
        marker = nil,
    }
    -- self.marker is (re)built lazily in onReaderReady, once self.capability
    -- has classified the document and we know which segmenter to use.
    self.marker = nil
    self.autoadvance = AutoAdvance:new{
        settings = self.settings,
        on_tick = function() return self:_onAutoAdvanceTick() end,
        get_text = function()
            return self.marker and self.marker.unit and self.marker.unit.text
        end,
    }
    self._key_hijacked = false
    self._orig_next_key_event = nil
    self._orig_prev_key_event = nil
    self._key_hook_installed = false
    -- True from onReaderReady (once the deferred resume/anchor callback is
    -- queued) until _resumeOrAnchor actually runs - see onReaderReady's
    -- comment for why the jump itself is deferred. While pending,
    -- _onNavigated() must NOT treat an incoming PageUpdate/PosUpdate as a
    -- manual page turn: rolling documents can fire a spurious, non-
    -- self-initiated one of these while the document is still settling
    -- (e.g. CreDocument's own initial page render), and marker.unit is nil
    -- at that point anyway - so "re-anchor to current page" would silently
    -- overwrite the not-yet-performed resume jump with "page 1".
    self._resume_pending = false

    Draw.install(self)
    self:_installHighlightHooks()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function Focusline:onDispatcherRegisterActions()
    Dispatcher:registerAction("focusline_toggle",
        {category="none", event="FocuslineToggle", title=_("Focusline: enable/disable marker"), reader=true})
    Dispatcher:registerAction("focusline_next_unit",
        {category="none", event="FocuslineNextUnit", title=_("Focusline: move marker forward"), reader=true})
    Dispatcher:registerAction("focusline_prev_unit",
        {category="none", event="FocuslinePrevUnit", title=_("Focusline: move marker backward"), reader=true})
    Dispatcher:registerAction("focusline_cycle_style",
        {category="none", event="FocuslineCycleStyle", title=_("Focusline: cycle marker style"), reader=true})
    Dispatcher:registerAction("focusline_toggle_auto_advance",
        {category="none", event="FocuslineToggleAutoAdvance", title=_("Focusline: toggle auto-advance"), reader=true})
    Dispatcher:registerAction("focusline_marker_here",
        {category="none", event="FocuslineMarkerHere", title=_("Focusline: move marker to this page"), reader=true})
end

-- Menu ----------------------------------------------------------------------

function Focusline:addToMainMenu(menu_items)
    menu_items.focusline = SettingsMenu.build(self)
end

-- Template resolution --------------------------------------------------------

-- The current style id + (enabled ? edge image id : nil), i.e. the two
-- independent choices composed into one look.
function Focusline:_currentEdgeImageId()
    if not self.settings:isEdgeImageEnabled() then
        return nil
    end
    return self.settings:getEdgeImageId()
end

-- The single {id, drawer, color} tuple lib/annotation_bridge.lua needs to
-- build/restyle the annotation item, resolved from settings (style + edge
-- image + color, composed - see lib/templates.lua's Templates.resolve).
function Focusline:_resolveTemplate()
    return Templates.resolve(self.settings, self.settings:getStyleId(), self:_currentEdgeImageId(),
        self.settings:getColorName())
end

-- Called by lib/draw.lua's patched ReaderView:drawHighlightRect. Must return
-- the composite catalog view (style_kind/edge_icon/edge_position), not the
-- resolved {id,drawer,color} tuple.
function Focusline:getCurrentTemplate()
    return Templates.resolveComposite(self.settings, self.settings:getStyleId(), self:_currentEdgeImageId())
end

-- Marker lifecycle ------------------------------------------------------

function Focusline:_ensureMarker()
    if not self.marker then
        self.marker = Marker:new{
            ui = self.ui,
            settings = self.settings,
            capability = self.capability,
        }
        self.resume.marker = self.marker
    end
    return self.marker
end

function Focusline:_isActive()
    return self.settings:isEnabled() and self.marker ~= nil and self.marker:isSupported()
end

-- Paint the marker at the marker's current unit (or do nothing if there is
-- none), writing through to the real annotation.
function Focusline:_syncAnnotationToMarker()
    if not self.marker or not self.marker.unit then
        return
    end
    self.bridge:setMarker(self.marker.unit, self:_resolveTemplate())
end

-- ReaderReady: classify the document, build the marker, then DEFER the
-- actual resume/anchor jump to a postReaderReadyCallback.
--
-- Why defer: ReaderRolling (rolling documents) registers its OWN
-- postReaderReadyCallback during its :init() - i.e. well before plugins
-- even load - which runs updatePos()+onRedrawCurrentView() AFTER the
-- "ReaderReady" event has finished dispatching to every module (readerui.lua
-- fires the event, THEN drains postReaderReadyCallback). onRedrawCurrentView
-- re-fires a plain PageUpdate for whatever page is current at that point,
-- with no way for us to tell it apart from a real manual page turn - so if
-- we jumped to the saved marker position synchronously inside onReaderReady
-- (i.e. during the "ReaderReady" event itself, before that callback runs),
-- this later re-fired PageUpdate would reach our onPageUpdate handler marked
-- "not self-initiated" and make _onNavigated() blindly re-anchor the marker
-- back to the first unit of the page - silently discarding the resumed
-- position (this was the "marker jumps back to the top on reopen" bug).
--
-- Registering our own postReaderReadyCallback from inside the ReaderReady
-- event handler still works (readerui.lua only starts draining the list
-- *after* the event finishes), and since table.insert always appends, our
-- entry lands after ReaderRolling's (added much earlier, at document-open
-- time) and therefore runs LAST - guaranteeing our jump is the final
-- navigation for this open, not racing against it.
function Focusline:onReaderReady()
    local kind = self.capability:getKind()
    self:_installKeyHijackHook()
    if kind == "unsupported" then
        -- Nothing more to do; onToggleEnabled() will show the notice if the
        -- user tries to turn focusline on for this document.
        return
    end
    self:_ensureMarker()
    self:_applyKeyHijack()
    if not self.settings:isEnabled() then
        return
    end
    self._resume_pending = true
    self.ui:registerPostReaderReadyCallback(function()
        self:_resumeOrAnchor()
    end)
end

function Focusline:_resumeOrAnchor()
    self._resume_pending = false
    if not self:_restoreMarker() then
        self.marker:anchorToCurrentPage()
        self:_syncAnnotationToMarker()
    end
    self:_startAutoAdvanceIfVisible()
end

-- Pick the marker back up from where the book's own saved annotation item
-- says it was. Returns false when there is nothing usable to restore (the
-- caller then starts a fresh marker at the top of the current page).
--
-- The marker's position must survive closing and reopening the book whether
-- or not "Jump to marker when reopening" is on. That setting only decides
-- what happens when the saved marker is NOT on the page the book reopens at:
--   - marker on the reopened page -> keep it exactly there, no navigation
--     (the common case: KOReader reopens at the last-read page, which is
--     where the marker was);
--   - marker elsewhere, jump on    -> go to the marker's page;
--   - marker elsewhere, jump off   -> with "Persistent marker" on, the
--     marker stays where it was saved, off screen; with it off, the marker
--     is not restorable here and follows the reader to the current page.
function Focusline:_restoreMarker()
    local anchor = self.bridge:getMarkerAnchor()
    if not anchor or not self.marker:anchorTo(anchor) then
        return false
    end
    if not self.marker:isOnScreen() and not self.resume:jumpToMarker()
        and not self.settings:isPersistentMarkerEnabled() then
        return false
    end
    -- The marker comes back looking the way it was left. Color is a global
    -- setting, so it may have been changed from another book since this
    -- item was saved: bring the menu in line with the restored marker
    -- rather than repainting the marker.
    self:_adoptMarkerStyle(self.bridge:getMarkerItem())
    return true
end

-- Enable/disable --------------------------------------------------------

function Focusline:onToggleEnabled()
    if not self.settings:isEnabled() then
        local kind = self.capability:getKind()
        if kind == "unsupported" then
            UnsupportedNotice.show()
            return
        end
        self.settings:setEnabled(true)
        self:_ensureMarker()
        self.marker:anchorToCurrentPage()
        self:_syncAnnotationToMarker()
        self:_applyKeyHijack()
        if self.settings:isAutoAdvanceEnabled() then
            self.autoadvance:start()
        end
    else
        self.settings:setEnabled(false)
        self.autoadvance:stop()
        self.bridge:clearMarker()
        if self.marker then
            self.marker:clear()
        end
        self:_applyKeyHijack()
    end
end

function Focusline:onFocuslineToggle()
    self:onToggleEnabled()
    return true
end

-- Granularity / template / style changes -----------------------------------

function Focusline:onSetGranularity(granularity)
    if not self:_ensureMarker() then return end
    self.marker:setGranularity(granularity, true)
    if self:_isActive() then
        self:_syncAnnotationToMarker()
    end
end

-- Re-resolve from current settings and restyle the live marker without
-- moving it. Called after ANY of style/edge-image/edge-enabled/color
-- changes - those are independent settings, but they all feed the same
-- resolved {id,drawer,color} tuple, so one shared refresh covers all of
-- them.
function Focusline:_refreshMarkerStyle()
    if self:_isActive() and self.bridge:isMarkerPresent() then
        self.bridge:restyleMarker(self:_resolveTemplate())
    end
end

function Focusline:onStyleChanged(style)
    self.settings:setStyleId(style.id, true)
    self:_refreshMarkerStyle()
end

function Focusline:onEdgeImageChanged(edge_image)
    self.settings:setEdgeImageId(edge_image.id, true)
    if not self.settings:isEdgeImageEnabled() then
        self.settings:setEdgeImageEnabled(true, true)
    end
    self:_refreshMarkerStyle()
end

function Focusline:onEdgeImageEnabledToggled()
    self.settings:setEdgeImageEnabled(not self.settings:isEdgeImageEnabled(), true)
    self:_refreshMarkerStyle()
end

function Focusline:onColorChanged(color_name)
    self.settings:setColorName(color_name)
    self:_refreshMarkerStyle()
end

-- Marker edits made OUTSIDE Focusline's own UI -----------------------------
--
-- Tapping the marker opens Focusline's popup, which routes every change
-- through onColorChanged/onStyleChanged above. But the marker is a real
-- annotation, so KOReader's own screens can still restyle it - notably the
-- bookmark list, whose style/color selectors write `item.color` /
-- `item.drawer` directly and then fire AnnotationsModified. Adopt such an
-- edit into the settings so the menu's "Style:" / "Color:" rows never
-- disagree with what is on the page.
function Focusline:onAnnotationsModified(items)
    local item = type(items) == "table" and items[1]
    if type(item) ~= "table" or not item.focusline_marker then
        return
    end
    if items.index_modified then
        return -- the marker being added/removed (i.e. moved): never a restyle
    end
    self:_adoptMarkerStyle(item)
end

-- Make the settings agree with the look the marker item actually has, then
-- re-resolve the item from those settings. The item wins: what is on the
-- page is what the reader chose, so it is the menu that follows.
function Focusline:_adoptMarkerStyle(item)
    if self._adopting_style or not item or not self:_isActive() then
        return
    end
    self._adopting_style = true
    if item.color and item.color ~= self.settings:getColorName() then
        self.settings:setColorName(item.color)
    end
    -- A stock drawer name ("underscore", "strikeout", ...) is also the id of
    -- the matching Focusline style (and the stock "lighten", which Focusline
    -- no longer offers, stands for Box). "focusline" itself carries no style
    -- information (it is what every hand-drawn style and any edge-image look
    -- resolves to).
    if item.drawer ~= "focusline" then
        local style = Templates.getStyleById(item.drawer)
        if style and style.id ~= self.settings:getStyleId() then
            self.settings:setStyleId(style.id, true)
        end
    end
    -- Re-resolve: e.g. a stock style picked while an edge image is on must
    -- go back to the composed "focusline" drawer to keep the icon. Does
    -- nothing when the item already matches.
    self:_refreshMarkerStyle()
    self._adopting_style = false
end

-- Marker popup actions (ui/marker_popup.lua) -------------------------------

-- Nudge the marker's start (side 0) or end (side 1) one word - or one
-- character - left (-1) or right (1), using KOReader's own boundary-adjust
-- code, then re-read the marker's unit from the adjusted item so the next
-- move continues from the adjusted span rather than the old one.
function Focusline:adjustMarkerBoundary(side, direction, move_by_char)
    local index = self.bridge:getMarkerIndex()
    if not index or not self.marker then
        return
    end
    self.ui.highlight:updateHighlight(index, side, direction, move_by_char)
    self.marker:anchorTo(self.bridge:getMarkerAnchor())
end

-- Take the marker off the page (same effect as deleting it from the stock
-- highlight dialog). Focusline stays enabled for the book: the marker comes
-- back at the next move, or at the top of the page on the next page turn
-- (also with "Persistent marker" on: there is no marker left to keep in
-- place, see _onNavigated).
function Focusline:removeMarker()
    self.autoadvance:stop()
    self:_clearMarkerAnnotationOnly()
end

-- Hooks into ReaderHighlight ------------------------------------------------
--
-- Installed on this document's ReaderHighlight INSTANCE (never the class),
-- so they vanish with the document and can't leak into the file browser or
-- the next book.
--
--   showHighlightNoteOrDialog / showHighlightDialog
--       What ReaderHighlight:onTap ends up calling for a tapped highlight.
--       For the Focusline marker, show ui/marker_popup.lua instead of the
--       stock dialog; every other highlight is passed through untouched.
--       Both are wrapped because a marker WITH a note would otherwise go to
--       the stock note viewer first (showHighlightNoteOrDialog), whose
--       "Highlight menu" button then calls showHighlightDialog.
--   getHighlightColorString
--       Maps a color name to its display label. Teach it Focusline's
--       palette names so KOReader's own screens (bookmark details, ...)
--       say "Muted Gold" rather than the internal "fl_gold".
--   getHighlightStyleString
--       Maps a drawer name to its display label, and returns nil for any
--       drawer it doesn't know - which the bookmark details screen then
--       feeds to table.concat and CRASHES on. The marker's "focusline"
--       drawer is such a name, so answer for it with the current style's
--       label.
function Focusline:_installHighlightHooks()
    local highlight = self.ui.highlight
    if not highlight or self._highlight_hooks then
        return
    end
    local fl = self
    local hooks = {}

    local function install(name, make_wrapper)
        local orig = highlight[name]
        if type(orig) ~= "function" then
            return
        end
        local wrapped = make_wrapper(orig)
        hooks[name] = { wrapped = wrapped, own = rawget(highlight, name) }
        highlight[name] = wrapped
    end

    local function dialogWrapper(orig)
        return function(hl, index, ...)
            local item = fl.ui.annotation.annotations[index]
            if item and item.focusline_marker and fl:_isActive() then
                MarkerPopup.show(fl)
                return
            end
            return orig(hl, index, ...)
        end
    end

    install("showHighlightNoteOrDialog", dialogWrapper)
    install("showHighlightDialog", dialogWrapper)
    install("getHighlightColorString", function(orig)
        return function(hl, color_name, ...)
            local entry = Colors.getById(color_name)
            if entry then
                return entry.label
            end
            return orig(hl, color_name, ...)
        end
    end)
    install("getHighlightStyleString", function(orig)
        return function(hl, drawer, ...)
            local label = orig(hl, drawer, ...)
            if label == nil and drawer == "focusline" then
                local style = Templates.getStyleById(fl.settings:getStyleId())
                label = style and style.label or _("Focusline")
            end
            return label
        end
    end)

    self._highlight_hooks = hooks
end

function Focusline:_removeHighlightHooks()
    local highlight = self.ui.highlight
    local hooks = self._highlight_hooks
    self._highlight_hooks = nil
    if not highlight or not hooks then
        return
    end
    for name, hook in pairs(hooks) do
        -- Only undo our own wrapper; if something else wrapped it after us,
        -- leave that chain alone.
        if rawget(highlight, name) == hook.wrapped then
            highlight[name] = hook.own
        end
    end
end

function Focusline:onFocuslineCycleStyle()
    if not self:_isActive() then
        return true
    end
    local ids = self.settings:getCycleStyleIds()
    if #ids == 0 then
        return true
    end
    local current_id = self.settings:getStyleId()
    local next_index = 1
    for i, id in ipairs(ids) do
        if id == current_id then
            next_index = i + 1
            break
        end
    end
    if next_index > #ids then
        next_index = 1
    end
    local next_style = Templates.getStyleById(ids[next_index])
    if next_style then
        self:onStyleChanged(next_style)
        if self.settings:isNotificationEnabled() then
            Notification:notify(T(_("Marker style: %1"), next_style.label))
        end
    end
    return true
end

-- Movement ----------------------------------------------------------------

function Focusline:_afterMove(moved)
    if not moved then
        return false
    end
    self:_syncAnnotationToMarker()
    return true
end

-- With "Persistent marker" on, the reader can turn pages and leave the marker
-- behind on the page it was on. A request to move it from there is answered
-- by going back to the marker first - same sentence, same page - and only
-- the next request moves it: the marker never moves while it is out of
-- sight, and the reader sees where they were before it goes on.
--
-- Returns true if that is what happened (the caller then does not move the
-- marker as well), false if the marker is on screen and can simply move.
function Focusline:_returnToMarker()
    local marker = self.marker
    if not marker.unit or marker:isOnScreen() then
        return false
    end
    if not self.bridge:isMarkerPresent() or not self.resume:goToMarker() then
        -- Nothing to go back to (the marker was deleted, or its place in the
        -- book can no longer be found): start again on the page shown.
        marker:anchorToCurrentPage()
        self:_syncAnnotationToMarker()
    end
    self:_startAutoAdvanceIfVisible()
    return true
end

-- Move the marker one unit forward (1) or backward (-1), on the reader's
-- request (a page-turn button, a gesture).
function Focusline:_moveMarker(direction)
    if self:_returnToMarker() then
        return
    end
    local moved
    if direction > 0 then
        moved = self.marker:moveNext()
    else
        moved = self.marker:movePrev()
    end
    self:_afterMove(moved)
    if not moved and direction > 0 then
        self:_maybeFinishBook()
    end
end

function Focusline:onFocuslineNextUnit()
    if self:_isActive() then
        self:_moveMarker(1)
    end
    return true
end

function Focusline:onFocuslinePrevUnit()
    if self:_isActive() then
        self:_moveMarker(-1)
    end
    return true
end

-- Put the marker on the first sentence/word of the page shown, wherever it
-- was. The way to bring a persistent marker along after skipping to another
-- part of the book.
function Focusline:onFocuslineMarkerHere()
    if not self:_isActive() then
        return true
    end
    if self.marker:anchorToCurrentPage() then
        self:_syncAnnotationToMarker()
        self:_startAutoAdvanceIfVisible()
    end
    return true
end

-- Configurable page-turn-button bindings -------------------------------------
--
-- Rather than registering our own (never-reached, see NEXT_KEY_NAME comment
-- above) key_events, we redirect ReaderPaging's/ReaderRolling's OWN
-- GotoNextPage/GotoNextView (and Prev counterparts) key_events entries to
-- fire our own event instead of GotoViewRel, while preserving their exact
-- key-match sequences and `args` (direction) - then fall back to the
-- original GotoViewRel behavior whenever the hijack setting is off, the
-- plugin is disabled, or the document is unsupported.

function Focusline:_pageModuleKind()
    if self.ui.paging then return "paging" end
    if self.ui.rolling then return "rolling" end
    return nil
end

function Focusline:_pageModule()
    return self.ui.paging or self.ui.rolling
end

-- Installed once per document: wraps the page module's registerKeyEvents
-- (AND the two event handlers KOReader aliases to it at class-definition
-- time - onPhysicalKeyboardConnected/onRegisterDPadEvents, see
-- readerpaging.lua/readerrolling.lua - which would otherwise bypass our
-- instance-level wrap entirely, since they capture the raw original
-- function, not a dynamic `self:registerKeyEvents()` call) so that whenever
-- KOReader itself re-registers key bindings (e.g. a physical keyboard
-- connects/disconnects), our hijack is reapplied on top instead of being
-- silently reset back to plain GotoViewRel.
function Focusline:_installKeyHijackHook()
    if self._key_hook_installed then
        return
    end
    local target = self:_pageModule()
    if not target or type(target.registerKeyEvents) ~= "function" then
        return
    end
    self._key_hook_installed = true
    local fl = self

    local function wrap(name)
        local orig_fn = target[name]
        if type(orig_fn) ~= "function" then
            return
        end
        target[name] = function(self_target, ...)
            -- The hijack redirected these entries' `.event` field; re-running
            -- the original would reset them, so mark ourselves un-hijacked
            -- first so _applyKeyHijack() does real work again afterwards.
            fl._key_hijacked = false
            local ret = orig_fn(self_target, ...)
            fl:_applyKeyHijack()
            return ret
        end
    end
    wrap("registerKeyEvents")
    wrap("onPhysicalKeyboardConnected")
    wrap("onRegisterDPadEvents")
end

function Focusline:_applyKeyHijack()
    local kind = self:_pageModuleKind()
    if not kind then
        return
    end
    local target = self:_pageModule()
    local next_name, prev_name = NEXT_KEY_NAME[kind], PREV_KEY_NAME[kind]
    local want_hijack = self.settings:getGlobal("hijack_page_turn_keys") == true
        and self:_isActive()

    if want_hijack then
        if not self._key_hijacked then
            self._orig_next_key_event = target.key_events[next_name]
            self._orig_prev_key_event = target.key_events[prev_name]
            self._key_hijacked = true
        end
        -- EventListener:handleEvent looks up `self[event.handler]` on the
        -- widget that OWNS the key_events table (ReaderPaging/ReaderRolling),
        -- not on us - so redirecting just the `.event` name isn't enough,
        -- we also install instance-local (not class-level) handler methods
        -- directly on `target` that delegate back into this plugin instance.
        local fl = self
        if target.key_events[next_name] then
            target.key_events[next_name].event = "FocuslineKeyNext"
            target.onFocuslineKeyNext = function(_target, args) return fl:onFocuslineKeyNext(args) end
        end
        if target.key_events[prev_name] then
            target.key_events[prev_name].event = "FocuslineKeyPrev"
            target.onFocuslineKeyPrev = function(_target, args) return fl:onFocuslineKeyPrev(args) end
        end
    else
        self:_restoreKeyHijack()
    end
end

function Focusline:_restoreKeyHijack()
    if not self._key_hijacked then
        return
    end
    local kind = self:_pageModuleKind()
    if kind then
        local target = self:_pageModule()
        local next_name, prev_name = NEXT_KEY_NAME[kind], PREV_KEY_NAME[kind]
        if self._orig_next_key_event and target.key_events[next_name] then
            target.key_events[next_name].event = self._orig_next_key_event.event
        end
        if self._orig_prev_key_event and target.key_events[prev_name] then
            target.key_events[prev_name].event = self._orig_prev_key_event.event
        end
        target.onFocuslineKeyNext = nil
        target.onFocuslineKeyPrev = nil
    end
    self._key_hijacked = false
end

function Focusline:onKeyBindingSettingsChanged()
    self:_applyKeyHijack()
end

-- `args` here is whatever the ORIGINAL GotoNextPage/GotoNextView key_events
-- entry carried (always `1` for next, `-1` for prev - see readerpaging.lua/
-- readerrolling.lua), preserved because we only overwrite the `.event`
-- field, never the whole table.
function Focusline:onFocuslineKeyNext(args)
    if not self:_isActive() then
        return self.ui:handleEvent(Event:new("GotoViewRel", args or 1))
    end
    self:_moveMarker(1)
    return true
end

function Focusline:onFocuslineKeyPrev(args)
    if not self:_isActive() then
        return self.ui:handleEvent(Event:new("GotoViewRel", args or -1))
    end
    self:_moveMarker(-1)
    return true
end

-- Auto-advance ----------------------------------------------------------

function Focusline:_onAutoAdvanceTick()
    if not self:_isActive() or not self.settings:isAutoAdvanceEnabled() then
        return false
    end
    if self.marker.unit and not self.marker:isOnScreen() then
        -- The marker was left on another page ("Persistent marker"): it does
        -- not move out of sight, and the reader is not pulled back to it.
        return false
    end
    local moved = self.marker:moveNext()
    if not moved then
        self:_maybeFinishBook()
        return false
    end
    self:_syncAnnotationToMarker()
    return true
end

function Focusline:onFocuslineToggleAutoAdvance()
    self.settings:setAutoAdvanceEnabled(not self.settings:isAutoAdvanceEnabled())
    self:onAutoAdvanceSettingsChanged()
    return true
end

function Focusline:onAutoAdvanceSettingsChanged()
    self.autoadvance:stop()
    self:_startAutoAdvanceIfVisible()
end

-- Start the auto-advance timer if it is switched on and the marker is on the
-- page shown; does nothing if it is already running. The timer never runs
-- while the marker is out of sight (see _onAutoAdvanceTick).
function Focusline:_startAutoAdvanceIfVisible()
    if self.autoadvance:isRunning() or not self:_isActive() or not self.settings:isAutoAdvanceEnabled() then
        return
    end
    if self.marker.unit and not self.marker:isOnScreen() then
        return
    end
    self.autoadvance:start()
end

-- Manual navigation -----------------------------------------------------------

-- Fired by readerrolling.lua/readerpaging.lua on every position/page change
-- (including ones WE trigger via GotoViewRel/GotoPage inside
-- lib/marker.lua's _advancePage). marker:consumeSelfInitiated() tells us
-- whether this particular change was ours; if not, the user paged/scrolled
-- manually. What happens then depends on "Persistent marker":
--
--   on (default)  the marker stays exactly where it is - same page, same
--                 sentence - however far the reader goes. Auto-advance is
--                 paused while the marker is out of sight and picks up
--                 again when the reader comes back to its page.
--   off           the marker follows the reader: it is re-anchored to the
--                 top of wherever they landed, and auto-advance is paused.
function Focusline:onPosUpdate()
    self:_onNavigated()
end

function Focusline:onPageUpdate()
    self:_onNavigated()
end

function Focusline:_onNavigated()
    if not self.marker then
        return
    end
    if self.marker:consumeSelfInitiated() then
        return
    end
    if self._resume_pending then
        -- The resume/anchor jump hasn't run yet (see onReaderReady); this
        -- PageUpdate/PosUpdate is incidental to the document still settling,
        -- not a real manual page turn - ignore it so it can't clobber the
        -- not-yet-performed resume with "page 1".
        return
    end
    if not self:_isActive() then
        return
    end
    local was_running = self.autoadvance:isRunning()
    -- A marker that has been deleted (or that ran off the end of the book)
    -- is not kept in place: there is nothing on the page to keep.
    local persistent = self.settings:isPersistentMarkerEnabled()
        and self.marker.unit ~= nil and self.bridge:isMarkerPresent()
    if persistent then
        if self.marker:isOnScreen() then
            -- Still on (or back on) the marker's page.
            self:_startAutoAdvanceIfVisible()
            return
        end
        self.autoadvance:pause()
    else
        self.autoadvance:pause()
        self.marker:anchorToCurrentPage()
        self:_syncAnnotationToMarker()
    end
    if was_running and self.settings:isNotificationEnabled() then
        Notification:notify(_("Focusline: auto-advance paused (manual page turn)"))
    end
end

-- End of book: remove the marker, it would otherwise sit on the last page
-- forever as a stray highlight.
function Focusline:onEndOfBook()
    self.autoadvance:stop()
    self:_clearMarkerAnnotationOnly()
end

function Focusline:_clearMarkerAnnotationOnly()
    if self.bridge:isMarkerPresent() then
        self.bridge:clearMarker()
    end
end

function Focusline:_maybeFinishBook()
    -- moveNext() returned false only at the true end of the document (no
    -- more pages/views to turn to); treat that the same as EndOfBook.
    self:_clearMarkerAnnotationOnly()
    self.autoadvance:stop()
end

-- Document close: nothing to persist beyond what's already in the
-- annotation/doc_settings (both auto-saved by KOReader itself), but make
-- sure the timer doesn't leak into the next document and the key hijack
-- doesn't leak into the next document's (different) ReaderPaging/
-- ReaderRolling instance.
function Focusline:onCloseWidget()
    self.autoadvance:stop()
    self:_restoreKeyHijack()
    self:_removeHighlightHooks()
    if Draw._active == self then
        Draw._active = nil
    end
end

return Focusline
