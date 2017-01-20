-- to-go.lua -- converts data emitted by from-jaredpar.lua to Go code

function main()
	-- read whole standard input and parse as Lua
	local prefixed = false
	local function read()
		if not prefixed then
			prefixed = true
			return "return "
		end
		return io.read()
	end
	local input = assert(load(read))()
end

main()

