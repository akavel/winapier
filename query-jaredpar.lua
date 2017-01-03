-- Query data from: https://github.com/jaredpar/pinvoke/master/tree/StorageGenerator/Data/windows.csv

inputPath = '../pinvoke/StorageGenerator/Data/windows.csv'

function main()
	local data = import(inputPath)
	dumpkv(data.CreateWindowExW)
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
			data[entry.name] = entry
		end
	end
	return data
end

function parse(r)
	local t = {
		nameKind = nameKind[r:int()]
	}
	if t.nameKind == 'Procedure' then
		return merge(t, parseProcedure(r))
	end
end
function parseProcedure(r)
	local t = {
		name = r:string(),
		calling = r:int(),
		dll = r:string(),
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
			name = r:string(),
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
	return t
end
function parseTypeRef(r)
	local t = {kind = symbolKind[r:int()]}
	if t.kind == 'ArrayType' then
		t.n = r:int()
		t.typ = parseTypeRef(r)
	elseif t.kind == 'BuiltinType' then
		t.builtin = r:int()
	elseif t.kind == 'PointerType' then
		t.base = parseTypeRef(r)
	elseif t.kind == 'NamedType' then
		t.qualif = r:string()
		t.name = r:string()
		t.const = r:bool()
	else
		error('unhandled symbolKind: '..t.kind)
	end
	return t
end

nameKind = {
	[0] = 'Struct',
	'Union',
	'FunctionPointer',
	'Procedure',
	'TypeDef',
	'Constant',
	'Enum',
	'EnumValue'
}
symbolKind = {
	[0] = 'StructType',
	'EnumType',
	'UnionType',
	'ArrayType',
	'PointerType',
	'BuiltinType',
	'TypeDefType',
	'BitVectorType',
	'NamedType',
	'Procedure',
	'ProcedureSignature',
	'FunctionPointer',
	'Parameter',
	'Member',
	'EnumNameValue',
	'Constant',
	'SalEntry',
	'SalAttribute',
	'ValueExpression',
	'Value',
	'OpaqueType'
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
			return self:next() == 'true'
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

main()
