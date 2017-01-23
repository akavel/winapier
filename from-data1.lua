INPUT_PATH = 'data1/StorageGenerator/Data/windows.csv'
USAGE = [[
Usage: lua from-data1.lua [OPTIONS] SYMBOL ...
Print definitions/signatures of listed WinAPI SYMBOLS, and all symbols
they depend on, in Lua table format.
Note: app requires an appropriately formatted WinAPI database to be
present in: ]] .. INPUT_PATH .. [[


OPTIONS:
  -d       don't print definitions of dependency symbols
  -h       keep Hungarian Notation prefixes in struct fields and signatures
           (by default, an attempt is made to remove them when detected)
  -o=FILE  print output to specified FILE instead of the standard output stream
  -i=FILE  use FILE as input WinAPI database, instead of default
]]

-- TODO: emit OCaml ctypes-foreign bindings, in Lua
-- TODO: add GPL licensing info
-- TODO: [LATER] write a readme, with info that the idea is to have
--       emitters+parsers of the same DB in various programming languages, for
--       ease of use in as many of them as possible
-- TODO: [LATER] change github.com/akavel/goheader to emit our own database and replace jaredpar's one with ours
-- TODO: [LATER] try changing the DB to some format similarly small but even
--       more trivial to parse (ideally common enough to have standard parsing
--       libs instead of needing custom parser, even that simple)
-- TODO: [LATER] try emitting json as an option
-- TODO: [LATER][BIG] add support for COM interfaces

-- global flags
keepHungarian = false

function main(...)
	local args = {...}
	if #args == 0 then
		args = {'RegisterClassEx', 'CreateWindowExW', 'TYSPEC', 'MEMCTX', 'CLSCTX', 'MKRREDUCE', 'EXCEPTION_DISPOSITION'}
	end

	-- parse options
	local deps = true
	local output = io.stdout
	local input = INPUT_PATH
	while #args > 0 and args[1]:sub(1,1) == '-' do
		if args[1] == '--help' or args[1] == '/?' then
			io.stderr:write(USAGE)
			os.exit(1)
		elseif args[1] == '-d' then
			deps = false
		elseif args[1] == '-h' then
			keepHungarian = true
		elseif args[1]:sub(1,3) == '-o=' then
			output = assert(io.open(args[1]:sub(4), 'w'))
		elseif args[1]:sub(1,3) == '-i=' then
			input = args[1]:sub(4)
		else
			io.stderr:write("error: unknown option "..args[1].."\n"..USAGE)
			os.exit(1)
		end
		table.remove(args, 1)
	end

	local data = import(input)
	local result = {}
	for _,v in ipairs(args) do
		if not result[v] then
			result[v] = data[v]
			squash(data, v) -- TODO(akavel): allow disabling this step with cmdline param
			if deps and data[v] then
				append_deps(data[v], args)
			end
		end
	end
	dumpt(result, output)
end

-- strip_hungarian removes Hungarian Notation prefix from provided symbol, if found.
function strip_hungarian(s)
	if keepHungarian then return s end
	if not s then return s end
	local hungarian = {'cb', 'dw', 'h', 'hbr', 'hWnd', 'lp', 'lpfn', 'lpsz', 'n'}
	-- Note: longest prefixes must be matched first, so we sort them this way
	table.sort(hungarian, function(a, b) return #a > #b end)
	for _, h in ipairs(hungarian) do
		local _, _, first, rest = s:find('^'..h..'(%u)(.*)')
		if first then
			return first:lower() .. rest
		end
	end
	return s
end

function append_deps(t, list)
	if t.nameKind == 'func' or t.nameKind == 'funcptr' then
		append_typ(t.ret, list)
		for _,v in ipairs(t.args) do
			append_typ(v.typ, list)
		end
	elseif t.nameKind == 'typedef' then
		append_typ(t.typ, list)
	elseif t.nameKind == 'struct' then
		for _,v in ipairs(t.members) do
			append_typ(v.typ, list)
		end
	elseif t.nameKind == 'const' then
		list[#list+1] = t.val
	end
end
function append_typ(t, list)
	if t.kind == 'name' then
		list[#list+1] = t.name
	elseif t.kind == 'pointer' then
		append_typ(t.to, list)
	end
end

-- squash simplifies name definition if it's just a redundant alias for a
-- different type.  For example, tagMKREDUCE can be removed to simplify
-- MKRREDUCE; similar for MEMCTX vs. tagMEMCTX.
function squash(data, name)
	local t = data[name]
	if t.nameKind == 'typedef' and t.typ.kind == 'name' then
		-- TODO(akavel): maybe skip squashing if typedef adds const qualifier?
		local target = t.typ.name
		-- delete old keys, copy new ones, but retain original name
		for k in pairs(t) do t[k] = nil end
		for k,v in pairs(data[target]) do t[k] = v end
		t.name = name
		return squash(data, name)
	end
end

function import(inputPath)
	local data = {}
	for line in io.lines(inputPath) do
		local r = Reader(line)
		local _, entry = xpcall(function() return parse(r) end, function(err)
			print(('ERROR: %s\nline= %s\ni= %d\n%s'):format(
				err, line, r.i, debug.traceback('', 2)))
			os.exit(1)
		end)
		if entry then
			-- entry.raw = line
			data[entry.name] = entry
		end
	end
	return data
end

function parse(r)
	local t = {
		nameKind = nameKind[r:int()]
	}
	if t.nameKind == 'func' then
		return merge(t, parseFunc(r))
	elseif t.nameKind == 'funcptr' then
		return merge(t, parseFuncPtr(r))
	elseif t.nameKind == 'typedef' then
		local t = merge(t, parseTypedef(r))
		-- Not sure why, but circular typedefs occur in the data
		if t.typ.name ~= t.name then
			return t
		end
	elseif t.nameKind == 'struct' or t.nameKind == 'union' then
		return merge(t, parseStruct(r))
	elseif t.nameKind == 'const' then
		return merge(t, parseConst(r))
	elseif t.nameKind == 'enum' then
		return merge(t, parseEnum(r))
	end
end
function parseEnum(r)
	local t = {
		name = r:string(),
		values = {},
	}
	local last = -1
	for i = 1, r:int() do
		local v = {
			name = r:string(),
			val = nil_empty(r:string()),
		}
		t.values[#t.values+1] = v
		if v.val then
			last = to_c_num(v.val)
			if last then
				v.ival = last
			end
		elseif last then
			last = last+1
			v.ival = last
		end
	end
	return t
end
function to_c_num(s)
	-- try to convert bit left shift
	local _, _, a, b = s:find '^%s*([1-9][0-9]*)%s*<<%s*([1-9][0-9]*)%s*$'
	if a then
		return (0+a)*(2^(0+b))
	end

	-- try to convert regular C-style number
	local ok, v = pcall(function()
		if s:sub(1,2) == '0x' then
			return tonumber(s:sub(3), 16)
		elseif s:sub(1,1) == '0' and #s > 1 then
			return tonumber(s:sub(2), 8)
		else
			return tonumber(s)
		end
	end)
	if ok then
		return v
	else
		return false
	end
end


function parseConst(r)
	return {
		name = r:string(),
		val = r:string(),
		kind = constantKind[r:int()],
	}
end
function parseStruct(r)
	local t = {
		name = r:string(),
		members = {},
	}
	for i = 1, r:int() do
		t.members[#t.members+1] = {
			name = strip_hungarian(r:string()),
			typ = parseTypeRef(r),
		}
	end
	return t
end
function parseTypedef(r)
	return {
		name = r:string(),
		typ = parseTypeRef(r),
	}
end
function parseFunc(r)
	local t = {
		name = r:string(),
		calling = callingConvention[r:int()],
		dll = r:string(),
	}
	return merge(t, parseSignature(r))
end
function parseFuncPtr(r)
	local t = {
		name = r:string(),
		calling = callingConvention[r:int()],
	}
	return merge(t, parseSignature(r))
end
function parseSignature(r)
	local t = {
		sal = parseSalAttr(r),
		ret = parseTypeRef(r),
		args = {},
	}
	for i = 1, r:int() do
		t.args[#t.args+1] = {
			name = nil_empty(strip_hungarian(r:string())),
			typ = parseTypeRef(r),
		}
	end
	return t
end
function parseSalAttr(r)
	local t = {}
	for i = 1, r:int() do
		t[#t+1] = {
			typ = r:int(),
			text = r:string(),
		}
	end
	if #t > 0 then
		return t
	end
end
function parseTypeRef(r)
	local t = {kind = symbolKind[r:int()]}
	if t.kind == 'array' then
		t.n = r:int()
		t.typ = parseTypeRef(r)
	elseif t.kind == 'builtin' then
		t.builtin = builtinType[r:int()]
	elseif t.kind == 'pointer' then
		t.to = parseTypeRef(r)
	elseif t.kind == 'name' then
		t.qualif = nil_empty(r:string())
		t.name = r:string()
		t.const = r:bool()
	elseif t.kind == 'BitVectorType' then
		t.n = r:int()
	else
		error('unhandled symbolKind: '..t.kind)
	end
	return t
end

nameKind = {
	[0] = 'struct',
	'union', -- 1
	'funcptr',
	'func',
	'typedef',
	'const', -- 5
	'enum',
	'EnumValue',
}
symbolKind = {
	[0] = 'StructType',
	'EnumType', -- 1
	'UnionType',
	'array',
	'pointer',
	'builtin', -- 5
	'TypeDefType',
	'BitVectorType',
	'name',
	'Procedure',
	'ProcedureSignature', -- 10
	'FunctionPointer',
	'Parameter',
	'Member',
	'EnumNameValue',
	'Constant', -- 15
	'SalEntry',
	'SalAttribute',
	'ValueExpression',
	'Value',
	'OpaqueType', -- 20
}
builtinType = {
	[0] = 'int16',
	'int32', -- 1
	'int64',
	'float',
	'double',
	'boolean', -- 5
	'char',
	'wchar',
	'byte',
	'void',
	'unknown', -- 10
}
constantKind = {
	[0] = 'Macro',
	'MacroMethod',
}
callingConvention = {
	[0] = 'default',
	'stdcall',
	'cdecl',
	'clrcall',
	'pascal',
	'inline',
}

function Reader(line)
	-- split on ','
	local parts = {}
	for part in line:gmatch '[^,]+' do
		parts[#parts+1] = part
	end
	return {
		parts = parts,
		i = 1,
		next = function(self)
			self.i = self.i+1
			return self.parts[self.i-1]
		end,
		int = function(self)
			return 0 + self:next()
		end,
		string = function(self)
			local s = self:next()
			if s:sub(1,1) == '0' then
				return nil
			end
			return s:sub(2):gsub('([^\\])#', '%1\\,'):gsub('^#', '\\,')
			:gsub('\\(.)', {
				['#']='#',
				[',']=',',
				['r']='\r',
				['n']='\n',
				['\\']='\\',
			})
		end,
		bool = function(self)
			return self:next() == 'true' or nil
		end,
	}
end
function merge(t, t2)
	for k,v in pairs(t2) do
		t[k] = v
	end
	return t
end
function dumpkv(tab, prefix)
	prefix = prefix or ''
	for k,v in pairs(tab) do
		if type(v) == 'table' then
			print(('%s%s='):format(prefix,k))
			dumpkv(v, prefix..'  ')
		else
			print(('%s%s= %s'):format(prefix,k,v))
		end
	end
end
function dumpt(t, output, indent)
	indent = (indent or '') .. '  '
	if type(t)=='table' then
		output:write '{'
		local max
		for i, v in ipairs(t) do
			max = i
			dumpt(v, output, indent)
			output:write ','
		end
		local more = false
		for k, v in pairs(t) do
			if type(k)~='number' or k<1 or k>max then
				if more then
					output:write ';'
				end
				more = true
				output:write '\n'
				output:write(indent)
				if type(k)=='string' then
					if k:match '^[%a_][%w_]*$' then
						output:write(k)
					else
						output:write(('[%q]'):format(k))
					end
					output:write '= '
					dumpt(v, output, indent)
				elseif type(k)=='number' then
					output:write(('[%d]= '):format(k))
					dumpt(v, output, indent)
				else
					error('unhandled key type: '..type(k))
				end
			end
		end
		output:write '}'
	elseif type(t)=='string' then
		output:write(('%q'):format(t))
	elseif type(t)=='number' then
		output:write(tostring(t))
	elseif type(t)=='boolean' then
		output:write(tostring(t))
	end
end

function nil_empty(s)
	if s ~= "" then
		return s
	end
end

main(...)
