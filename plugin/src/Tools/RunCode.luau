local Main = script:FindFirstAncestor("MCPStudioPlugin")
local LuauCompile = require(Main.Utils.LuauCompile)
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

-- Keeps the last `maxLines` lines of captured output, prepending a notice
-- about how many earlier lines were dropped. The important parts (returned
-- results, errors) are appended last, so the tail is what we keep.
local function truncateOutput(output: string, maxLines: number): string
	if maxLines <= 0 then
		return output
	end
	-- Each entry ends with "\n"; drop one trailing newline for clean splitting.
	local trimmed = if string.sub(output, -1) == "\n" then string.sub(output, 1, -2) else output
	if trimmed == "" then
		return output
	end
	local lines = string.split(trimmed, "\n")
	if #lines <= maxLines then
		return output
	end
	local dropped = #lines - maxLines
	local kept = table.move(lines, dropped + 1, #lines, 1, {})
	return string.format("[TRUNCATED] %d earlier line(s) omitted; showing the last %d.\n", dropped, maxLines)
		.. table.concat(kept, "\n")
		.. "\n"
end

local function runCodeWithOutput(command: string, maxLines: number?): string
	local output = ""

	local function getTableType(arg)
		local hasArray = false
		local hasTable = false
		for key, _value in arg do
			if typeof(key) == "number" then
				hasArray = true
			else
				hasTable = true
			end
			if hasArray and hasTable then
				break
			end
		end
		return hasArray, hasTable
	end

	local function serializeTable(arg): any
		if typeof(arg) == "table" then
			local _, isTable = getTableType(arg)

			local newArg = {}
			for key, value in arg do
				local newKey = serializeTable(key)
				newArg[if isTable then tostring(newKey) else newKey] = serializeTable(value)
			end
			return newArg
		elseif type(arg) == "userdata" then
			return tostring(arg) or "UNABLE_TO_SERIALIZE"
		end
		return arg
	end

	local function deepClone(t, cache)
		local clone = {}
		for key, value in t do
			local newKey = key
			if typeof(key) == "table" then
				if not cache[key] then
					cache[key] = deepClone(key, cache)
				end
				newKey = cache[key]
			end

			local newValue = value
			if typeof(value) == "table" then
				if not cache[value] then
					cache[value] = deepClone(value, cache)
				end
				newValue = cache[value]
			end

			clone[newKey] = newValue
		end
		return clone
	end

	local function toStrTable(t: { any }): { string }
		local clonedTable = deepClone(t, {})
		-- table.pack keeps the argument count in "n"; trust it over # so nil
		-- arguments still render as "nil" instead of truncating the output.
		local count = (clonedTable :: any).n or #clonedTable
		local strTable = table.create(count)
		for i = 1, count do
			local serializedArg = serializeTable(clonedTable[i])
			strTable[i] = if typeof(serializedArg) == "table"
				then HttpService:JSONEncode(serializedArg)
				elseif typeof(serializedArg) == "string" then serializedArg
				else tostring(serializedArg)
		end
		return strTable
	end

	local function addToOutput(header: string, ...)
		local strResults = toStrTable(table.pack(...))
		output ..= header .. " " .. table.concat(strResults, "\t") .. "\n"
	end

	local function executeCode()
		local chunk = LuauCompile.compile(command, script)
		local chunkfenv = getfenv(chunk)

		local oldPrint = print
		chunkfenv.print = function(...)
			oldPrint(...)
			addToOutput("[OUTPUT]", ...)
		end

		local oldWarn = warn
		chunkfenv.warn = function(...)
			oldWarn(...)
			addToOutput("[WARNING]", ...)
		end

		local oldError = error
		chunkfenv.error = function(...)
			oldError(...)
			addToOutput("[ERROR]", ...)
		end

		local results = table.pack(chunk())
		if #results > 0 then
			addToOutput("[RETURNED RESULTS]", table.unpack(results))
		end

		return results
	end

	local ok, errorMessage = pcall(executeCode)
	if not ok then
		addToOutput("[UNEXPECTED ERROR]", errorMessage)
	end

	if type(maxLines) == "number" then
		output = truncateOutput(output, maxLines)
	end

	return output
end

-- Pure execute: compile and run the chunk directly without overriding its
-- environment (no getfenv/setfenv) and without capturing print/warn/error.
-- Any prints still reach the real console (readable via get_console_output).
-- Errors propagate to the dispatcher and surface as a tool failure.
local function runCodePure(command: string): string
	local chunk = LuauCompile.compile(command, script)
	chunk()
	return "Executed (execute mode: output not captured; read prints via get_console_output)."
end

local function handleRunCode(runCodeArgs: Types.RunCodeArgs): string?
	if type(runCodeArgs.command) ~= "string" then
		error("Missing command in RunCode")
	end

	if runCodeArgs.mode == "execute" then
		return runCodePure(runCodeArgs.command)
	end

	return runCodeWithOutput(runCodeArgs.command, runCodeArgs.max_lines)
end

return handleRunCode :: Types.ToolFunction
