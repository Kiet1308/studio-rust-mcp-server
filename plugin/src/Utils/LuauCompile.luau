--[[
	Compiles a source string into a callable function. loadstring() is
	unavailable in play-mode DataModels, so this falls back to requiring a
	throwaway ModuleScript: plugin context may write Source, and require()
	compiles it in the calling VM.
]]

local LuauCompile = {}

function LuauCompile.compile(source: string, host: Instance): (...any) -> ...any
	local okLoad, chunk = pcall(loadstring :: any, source)
	if okLoad and chunk then
		return chunk
	end
	local container = Instance.new("ModuleScript")
	container.Name = "MCPCompiledChunk"
	container.Source = "return function(...)\n" .. source .. "\nend"
	container.Parent = host
	local okRequire, result = pcall(require, container :: any)
	container:Destroy()
	if not okRequire then
		error("Failed to compile code: " .. tostring(result))
	end
	return result
end

return LuauCompile
