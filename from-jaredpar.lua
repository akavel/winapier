-- from-jaredpar.lua -- parses the WinAPI database from [jaredpar/pinvoke][1]
-- project, queries it about specified symbols and optionally their
-- dependencies, then prints the results in Lua table format.
--
-- [1]: https://github.com/jaredpar/pinvoke/master/tree/StorageGenerator/Data/windows.csv
--
-- TODO: add [jaredpar/pinvoke][1] as a subproject
-- TODO: emit OCaml ctypes-foreign bindings, in Lua
-- TODO: add GPL licensing info
-- TODO: add --help (and /?) option and usage info
-- TODO: simplify tagFOOBAR types (e.g. tagMKREDUCE vs. MKRREDUCE, or tagMEMCTX vs. MEMCTX)
-- TODO: [LATER] write a readme, with info that the idea is to have
--       emitters+parsers of the same DB in various programming languages, for
--       ease of use in as many of them as possible
-- TODO: [LATER] emit Go bindings
-- TODO: [LATER] change github.com/akavel/goheader to emit our own database and replace jaredpar's one with ours
-- TODO: [LATER] try changing the DB to some format similarly small but even
--       more trivial to parse (ideally common enough to have standard parsing
--       libs instead of needing custom parser, even that simple)
-- TODO: [LATER] try emitting json as an option
-- TODO: [LATER][BIG] add support for COM interfaces

inputPath = '../pinvoke/StorageGenerator/Data/windows.csv'

-- global flags
keepHungarian = false

function main(...)
	local data = import(inputPath)
	local args = {...}
	if #args == 0 then
		args = {'-d', 'RegisterClassEx', 'CreateWindowExW', 'TYSPEC', 'MEMCTX', 'CLSCTX', 'MKRREDUCE', 'EXCEPTION_DISPOSITION'}
	end

	-- parse options
	local deps = false
	while #args > 0 and args[1]:sub(1,1) == '-' do
		if args[1] == '-d' then
			deps = true
		elseif args[1] == '-h' then
			keepHungarian = true
		else
			io.stderr:write("error: unknown option "..args[1].."\n")
			os.exit(1)
		end
		table.remove(args, 1)
	end

	local result = {}
	for _,v in ipairs(args) do
		if not result[v] then
			result[v] = data[v]
			if deps and data[v] then
				append_deps(data[v], args)
			end
		end
	end
	dumpt(result)
end

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
function dumpt(t, indent)
	indent = (indent or '') .. '  '
	if type(t)=='table' then
		io.write '{'
		local max
		for i, v in ipairs(t) do
			max = i
			dumpt(v, indent)
			io.write ','
		end
		local more = false
		for k, v in pairs(t) do
			if type(k)~='number' or k<1 or k>max then
				if more then
					io.write ';'
				end
				more = true
				io.write '\n'
				io.write(indent)
				if type(k)=='string' then
					if k:match '^[%a_][%w_]*$' then
						io.write(k)
					else
						io.write(('[%q]'):format(k))
					end
					io.write '= '
					dumpt(v, indent)
				elseif type(k)=='number' then
					io.write(('[%d]= '):format(k))
					dumpt(v, indent)
				else
					error('unhandled key type: '..type(k))
				end
			end
		end
		-- if more then
		-- 	io.write '\n'
		-- 	io.write(indent)
		-- end
		io.write '}'
	elseif type(t)=='string' then
		io.write(('%q'):format(t))
	elseif type(t)=='number' then
		io.write(tostring(t))
	elseif type(t)=='boolean' then
		io.write(tostring(t))
	end
end

function nil_empty(s)
	if s ~= "" then
		return s
	end
end

main(...)
