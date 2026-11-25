--[[--
Catalogs for the two independent axes of the marker's look:

  STYLES      -- how the marked text itself is rendered: a box, a border, a
                 pinned band, a stock KOReader highlight look (underline/
                 strikethrough/invert), or one of the hand-drawn underlines
                 (dashed, dotted, double, wavy, and the ornament ones).
                 Exactly one style is active at a time. Not user-extensible
                 (these are drawing algorithms, not assets).
  EDGE IMAGES -- an optional decorative PNG/SVG icon composited just outside
                 the marked text's bounding box (flower/star/leaf/arrow/
                 user-imported). Independent of style: can be layered on top
                 of ANY style, or turned off entirely
                 (`Settings:isEdgeImageEnabled()`). User-extensible via
                 "Import PNG/SVG…", which only exists in the edge-image
                 picker - styles have no import flow.

Schema (style entry):
    { id = "box", label = _("Box"), kind = "box" }
    -- `kind` is either a stock KOReader drawer name ("underscore" |
    -- "strikeout" | "invert", rendered via KOReader's OWN drawing code so it
    -- looks and edits identically to a normal highlight) or one of
    -- focusline's own hand-drawn kinds ("box" | "border" | "pinned" |
    -- "underline_wavy" | "underline_double" | "underline_dashed" |
    -- "underline_dotted" | the ornament underlines). "Lighten" used to be
    -- offered too, but its translucent fill looked the same as "Box" on
    -- screen, so it was dropped in favor of the new "Pinned" look rather
    -- than keep two near-identical options (a style_id of "lighten" saved by
    -- an older version resolves to "Box", see STYLE_ALIASES below).

Schema (edge image entry):
    {
        id            = "edge_star",
        label         = _("Star"),
        edge_icon     = "icons/star.svg", -- path relative to the plugin root
        edge_position = "left"|"right"|"top"|"bottom",
        user_imported = true, -- only present on user-added entries
    }

`color` is deliberately part of neither catalog: color is a per-document (or
global default) user choice, orthogonal to both style and edge image, stored
separately in settings (`color_name`).

Resolution (`Templates.resolve`/`Templates.resolveComposite`) composes a
chosen style id + an optional edge image id (nil when the edge-image overlay
is disabled) into what `lib/annotation_bridge.lua` and `lib/draw.lua`
respectively need - see those files' doc comments for the exact shapes.
--]]--

local _ = require("gettext")

local Templates = {}

-- The stock-drawer-backed styles are offered so the marker can look exactly
-- like a normal highlight if the user prefers that over focusline's own
-- hand-drawn looks; everything else here has no native KOReader drawer and
-- is hand-drawn in lib/draw.lua.
Templates.STYLES = {
    { id = "box", label = _("Box"), kind = "box" },
    { id = "border", label = _("Border"), kind = "border" },
    { id = "pinned", label = _("Pinned"), kind = "pinned" },
    { id = "underscore", label = _("Underline"), kind = "underscore" },
    { id = "underline_dashed", label = _("Underline (dashed)"), kind = "underline_dashed" },
    { id = "underline_dotted", label = _("Underline (dotted)"), kind = "underline_dotted" },
    { id = "underline_double", label = _("Underline (double)"), kind = "underline_double" },
    { id = "underline_wavy", label = _("Underline (wavy)"), kind = "underline_wavy" },
    -- Ornament underlines: a line with a small drawing at its ends or in its
    -- middle, like a page divider (drawings in ornaments/, see lib/draw.lua).
    { id = "underline_diamond", label = _("Underline (diamonds)"), kind = "underline_diamond" },
    { id = "underline_flourish", label = _("Underline (flourish)"), kind = "underline_flourish" },
    { id = "underline_leaves", label = _("Underline (leaves)"), kind = "underline_leaves" },
    { id = "underline_scroll", label = _("Underline (scroll)"), kind = "underline_scroll" },
    { id = "underline_flower", label = _("Underline (flower)"), kind = "underline_flower" },
    { id = "underline_bow", label = _("Underline (bow)"), kind = "underline_bow" },
    { id = "underline_quill", label = _("Underline (quill)"), kind = "underline_quill" },
    { id = "strikeout", label = _("Strikethrough"), kind = "strikeout" },
    { id = "invert", label = _("Invert"), kind = "invert" },
}

-- Ids of styles that no longer exist, and the style that takes their place
-- wherever one is still stored (a book's settings, the quick-style list).
local STYLE_ALIASES = {
    lighten = "box",
}

Templates.EDGE_IMAGES_BUILTIN = {
    { id = "edge_flower", label = _("Flower"), edge_icon = "icons/flower.svg", edge_position = "left" },
    { id = "edge_star", label = _("Star"), edge_icon = "icons/star.svg", edge_position = "left" },
    { id = "edge_leaf", label = _("Leaf"), edge_icon = "icons/leaf.svg", edge_position = "left" },
    { id = "edge_arrow", label = _("Arrow"), edge_icon = "icons/arrow.svg", edge_position = "right" },
}

local STYLES_BY_ID = {}
for _, t in ipairs(Templates.STYLES) do
    STYLES_BY_ID[t.id] = t
end

local EDGE_BUILTIN_BY_ID = {}
for _, t in ipairs(Templates.EDGE_IMAGES_BUILTIN) do
    EDGE_BUILTIN_BY_ID[t.id] = t
end

-- Styles -----------------------------------------------------------------
-- Not user-extensible, so no Settings dependency needed for these two.

function Templates.getStyles()
    return Templates.STYLES
end

function Templates.getStyleById(id)
    return STYLES_BY_ID[id] or STYLES_BY_ID[STYLE_ALIASES[id]]
end

-- Edge images --------------------------------------------------------------

-- Returns the full list of edge images (built-ins + user-imported, in that
-- order) for a given Settings instance.
function Templates.getEdgeImages(settings)
    local list = {}
    for _, t in ipairs(Templates.EDGE_IMAGES_BUILTIN) do
        table.insert(list, t)
    end
    for _, t in ipairs(settings:getUserEdgeImages()) do
        table.insert(list, t)
    end
    return list
end

function Templates.getEdgeImageById(settings, id)
    if not id then
        return nil
    end
    if EDGE_BUILTIN_BY_ID[id] then
        return EDGE_BUILTIN_BY_ID[id]
    end
    for _, t in ipairs(settings:getUserEdgeImages()) do
        if t.id == id then
            return t
        end
    end
    return nil
end

-- Register a new user-imported edge image (icon already copied into
-- icons/user_imports/ by the caller). Returns the new entry table.
function Templates.addUserEdgeImage(settings, label, icon_relpath, edge_position)
    local list = settings:getUserEdgeImages()
    local id = "user_" .. tostring(os.time()) .. "_" .. tostring(#list + 1)
    local t = {
        id = id,
        label = label,
        edge_icon = icon_relpath,
        edge_position = edge_position or "left",
        user_imported = true,
    }
    table.insert(list, t)
    settings:setUserEdgeImages(list)
    return t
end

function Templates.removeUserEdgeImage(settings, id)
    local list = settings:getUserEdgeImages()
    for i, t in ipairs(list) do
        if t.id == id then
            table.remove(list, i)
            settings:setUserEdgeImages(list)
            return true
        end
    end
    return false
end

function Templates.renameUserEdgeImage(settings, id, new_label)
    local list = settings:getUserEdgeImages()
    for _, t in ipairs(list) do
        if t.id == id then
            t.label = new_label
            settings:setUserEdgeImages(list)
            return true
        end
    end
    return false
end

-- Composition --------------------------------------------------------------

-- Build the `{id, drawer, color}` tuple lib/annotation_bridge.lua expects,
-- from a style id + an optional edge image id (nil/false = no edge image
-- overlay, matching `Settings:isEdgeImageEnabled()` being off) + color name.
--
-- Style kinds KOReader itself already knows how to draw (readerview.lua's
-- drawHighlightRect); every other kind is one of focusline's own hand-drawn
-- looks and must go through the "focusline" drawer instead (see
-- lib/draw.lua).
local STOCK_KINDS = { underscore = true, strikeout = true, invert = true }

-- `drawer` is "focusline" (focusline's own paint routine, see lib/draw.lua)
-- whenever any custom compositing is needed - i.e. whenever an edge image is
-- layered on, or the style itself has no stock KOReader equivalent. A plain
-- stock style with no edge image keeps using KOReader's own drawer string,
-- so it renders/edits identically to a normal highlight (e.g. its color
-- swatch in the stock highlight-edit dialog).
function Templates.resolve(settings, style_id, edge_image_id, color_name)
    local style = Templates.getStyleById(style_id) or STYLES_BY_ID.box
    local edge = Templates.getEdgeImageById(settings, edge_image_id)
    local drawer
    if edge or not STOCK_KINDS[style.kind] then
        drawer = "focusline"
    else
        drawer = style.kind -- "underscore" | "strikeout" | "invert"
    end
    local id = style.id .. (edge and ("+" .. edge.id) or "")
    return { id = id, drawer = drawer, color = color_name }
end

-- Build the composite catalog view lib/draw.lua's live drawHighlightRect
-- patch needs to paint the CURRENT marker: the style's kind plus the edge
-- image's icon/position, if any.
function Templates.resolveComposite(settings, style_id, edge_image_id)
    local style = Templates.getStyleById(style_id) or STYLES_BY_ID.box
    local edge = Templates.getEdgeImageById(settings, edge_image_id)
    return {
        style_kind = style.kind,
        edge_icon = edge and edge.edge_icon or nil,
        edge_position = edge and edge.edge_position or nil,
    }
end

return Templates
