--[[--
Picks the rolling or paging segmenter implementation based on
`lib/capability.lua`'s classification, and exposes it under one name so
`lib/marker.lua` never needs to know which one it's talking to.
--]]--

local RollingSegmenter = require("lib/segmenter/rolling")
local PagingSegmenter = require("lib/segmenter/paging")

local Segmenter = {}

-- capability: lib/capability.lua instance, already attached to this doc's ui.
function Segmenter.create(ui, capability)
    if capability:isRolling() then
        return RollingSegmenter:new{ ui = ui }
    elseif capability:isPaging() then
        return PagingSegmenter:new{ ui = ui }
    end
    return nil
end

return Segmenter
