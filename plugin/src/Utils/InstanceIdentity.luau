--[[
	Identifies which Studio window a DataModel belongs to, for routing when
	several Studio windows are open at once.

	The edit DataModel derives its id from PlaceId+Name. Play DataModels
	cannot: an unsaved local place renames its play clones to "Game", so the
	id would not match the edit window it came from. Instead, the edit side
	marks itself as the imminent "play owner" in plugin settings (shared
	across DataModels) right before starting a play session, and freshly
	booted play DataModels adopt that id.

	Limitations: a play session started manually (F5) without the MCP tools
	registers under its own raw id, and two play sessions started in the same
	instant could adopt the same owner.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local PluginUtils = require(Main.Utils.PluginUtils)

local OWNER_KEY = "MCP_PLAY_OWNER"
-- How old the owner mark may be for a booting play DataModel to trust it.
local OWNER_FRESH_SECONDS = 30

local InstanceIdentity = {}

function InstanceIdentity.computeRaw(): string
	return tostring(game.PlaceId) .. "|" .. game.Name
end

-- Called by the edit DataModel right before it starts a play session.
function InstanceIdentity.markPlayOwner(instanceId: string)
	pcall(function()
		PluginUtils.setSettings(OWNER_KEY, instanceId .. ";" .. os.time())
	end)
end

-- Called by booting play DataModels: prefer the freshly marked owner id,
-- fall back to the raw id (manual F5 sessions land here).
function InstanceIdentity.adoptForPlay(rawId: string): string
	local ok, value = pcall(function()
		return PluginUtils.getSettings(OWNER_KEY)
	end)
	if not ok or type(value) ~= "string" then
		return rawId
	end
	local id, timestamp = string.match(value, "^(.*);(%d+)$")
	if not id or id == "" then
		return rawId
	end
	if os.time() - tonumber(timestamp) > OWNER_FRESH_SECONDS then
		return rawId
	end
	return id
end

return InstanceIdentity
