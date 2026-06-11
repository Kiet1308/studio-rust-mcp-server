--[[
	Fast buffer-based base64 encoder. Encoding a full-screen RGBA capture
	(~5 MB) takes on the order of a second, well within tool timeouts.
]]

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PAD = 61 -- '='

local lut = buffer.create(64)
for i = 1, 64 do
	buffer.writeu8(lut, i - 1, string.byte(ALPHABET, i))
end

local Base64 = {}

function Base64.encode(input: buffer): string
	local n = buffer.len(input)
	local fullChunks = math.floor(n / 3)
	local rem = n - fullChunks * 3
	local outLen = (fullChunks + (if rem > 0 then 1 else 0)) * 4
	local output = buffer.create(outLen)
	local si, di = 0, 0
	for _ = 1, fullChunks do
		local b0 = buffer.readu8(input, si)
		local b1 = buffer.readu8(input, si + 1)
		local b2 = buffer.readu8(input, si + 2)
		buffer.writeu8(output, di, buffer.readu8(lut, bit32.rshift(b0, 2)))
		buffer.writeu8(output, di + 1, buffer.readu8(lut, bit32.bor(bit32.lshift(bit32.band(b0, 3), 4), bit32.rshift(b1, 4))))
		buffer.writeu8(output, di + 2, buffer.readu8(lut, bit32.bor(bit32.lshift(bit32.band(b1, 15), 2), bit32.rshift(b2, 6))))
		buffer.writeu8(output, di + 3, buffer.readu8(lut, bit32.band(b2, 63)))
		si += 3
		di += 4
	end
	if rem == 1 then
		local b0 = buffer.readu8(input, si)
		buffer.writeu8(output, di, buffer.readu8(lut, bit32.rshift(b0, 2)))
		buffer.writeu8(output, di + 1, buffer.readu8(lut, bit32.lshift(bit32.band(b0, 3), 4)))
		buffer.writeu8(output, di + 2, PAD)
		buffer.writeu8(output, di + 3, PAD)
	elseif rem == 2 then
		local b0 = buffer.readu8(input, si)
		local b1 = buffer.readu8(input, si + 1)
		buffer.writeu8(output, di, buffer.readu8(lut, bit32.rshift(b0, 2)))
		buffer.writeu8(output, di + 1, buffer.readu8(lut, bit32.bor(bit32.lshift(bit32.band(b0, 3), 4), bit32.rshift(b1, 4))))
		buffer.writeu8(output, di + 2, buffer.readu8(lut, bit32.lshift(bit32.band(b1, 15), 2)))
		buffer.writeu8(output, di + 3, PAD)
	end
	return buffer.tostring(output)
end

return Base64
