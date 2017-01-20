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

	-- emit entities
	for name, entity in pairs(input) do
		if entity.nameKind == 'struct' then
			-- TODO(akavel): check if using lustache or some other (Go-like?) templating engine simplifies stuff
			printf("type %s struct {\n", entity.name)
			for _, m in ipairs(entity.members) do
				printf("\t%s %s\n", m.name, format_type(m.typ))
			end
			printf("}\n")
		elseif entity.nameKind == 'typedef' then
			printf("type %s %s\n", entity.name, format_type(entity.typ))
		else
			error('unknown entity nameKind: '..entity.nameKind)
		end
	end
end

function format_type(typ)
	if typ.kind == 'builtin' then
		local builtins = {int32='int32', int16='int16'}
		return assert(builtins[typ.builtin], 'unknown builtin: '..typ.builtin)
	elseif typ.kind == 'pointer' then
		return '*' .. format_type(typ.to)
	elseif typ.kind == 'name' then
		return typ.name
	else
		error('unknown type kind: '..typ.kind)
	end
end

function printf(fmt, ...)
	io.write(fmt:format(...))
end

main()

