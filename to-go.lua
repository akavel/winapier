USAGE = [[
Usage: lua to-go.lua [OPTIONS]
Load definitions of WinAPI symbols formatted as Lua tables,
then emit corresponding signatures in Go source code format.

OPTIONS:
  -i=FILE     load Lua tables from specified FILE instead of the standard input stream
  -o=FILE     print output to specified FILE instead of the standard output stream
  -p=PACKAGE  emit `package PACKAGE` line as first output instead of default "main"
]]

data = {}
output = io.stdout

function main(...)
	-- parse options
	local args = {...}
	local input = io.stdin
	local package = "main"
	while #args > 0 and args[1]:sub(1,1) == '-' do
		if args[1]:sub(1,3) == '-i=' then
			input = assert(io.open(args[1]:sub(4), 'r'))
		elseif args[1]:sub(1,3) == '-o=' then
			output = assert(io.open(args[1]:sub(4), 'w'))
		elseif args[1]:sub(1,3) == '-p=' then
			package = args[1]:sub(4)
		else
			io.stderr:write("error: unknown option "..args[1].."\n"..USAGE)
			os.exit(1)
		end
		table.remove(args, 1)
	end

	-- read whole standard input and parse as Lua
	local prefixed = false
	local function read()
		if not prefixed then
			prefixed = true
			return "return "
		end
		return input:read()
	end
	data = assert(load(read))()

	-- emit common preamble
	printf([[
package %s

import "unsafe"
import "syscall"

var _ = unsafe.Pointer
var _ = syscall.MustLoadDLL

func frombool(b bool) uintptr {
	if b {
		return 1
	} else {
		return 0
	}
}

]], package)

	-- emit entities
	for name, entity in pairs(data) do
		if entity.nameKind == 'struct' then
			-- TODO(akavel): check if using lustache or some other (Go-like?) templating engine simplifies stuff
			printf("type %s struct {\n", upcase(entity.name))
			for _, m in ipairs(entity.members) do
				printf("\t%s %s\n", upcase(m.name), format_type(m.typ))
			end
			printf("}\n")
		elseif entity.nameKind == 'typedef' then
			printf("type %s %s\n", upcase(entity.name), format_type(entity.typ))
		elseif entity.nameKind == 'enum' then
			-- TODO(akavel): int, or int32, or int64, or...?
			printf("type %s int\n", upcase(entity.name))
			printf("const (\n")
			for _, v in ipairs(entity.values) do
				if v.ival and v.val then
					printf("\t%s %s = %d /* = %s */\n",
						upcase(v.name), upcase(entity.name), v.ival, v.val)
				elseif v.ival then
					printf("\t%s %s = %d\n",
						upcase(v.name), upcase(entity.name), v.ival)
				else
					printf("\t// FIXME: %s %s = %s\n",
						v.name, entity.name, v.val)
				end
			end
			printf(")\n")
		elseif entity.nameKind == 'const' then
			if entity.kind == 'Macro' then
				printf("/* FIXME: #define %s %s */\n", entity.name, entity.val)
			else
				error('unknown const kind: '..entity.kind)
			end
		elseif entity.nameKind == 'func' then
			emit_func(entity)
		elseif entity.nameKind == 'funcptr' then
			local callback =
				entity.calling == 'cdecl' and 'syscall.NewCallbackCDecl' or
				entity.calling == 'stdcall' and 'syscall.NewCallback' or
				entity.calling
			printf("type %s uintptr // NOTE: %s(func%s)\n",
				entity.name, callback, format_signature(entity))
		else
			error('unknown entity nameKind: '..entity.nameKind)
		end
	end
end

function emit_func(f)
	-- TODO(akavel): try emitting funcs as structs with Call method, to simulate named params,
	-- to make it easier to omit some params.

	-- helper variable
	printf('\nvar proc%s = syscall.MustLoadDLL("%s").MustFindProc("%s")\n\n',
		f.name, f.dll, f.name)

	-- func signature
	printf("func %s%s {\n", f.name, format_signature(f, true))

	-- func body - call
	printf("\tr1, _, lastErr := proc%s.Call(", f.name)
	for i, arg in ipairs(f.args) do
		if i > 1 then printf(", ") end
		local kind = arg.typ.kind
		local name = named_arg(arg.name, i)
		if kind == 'builtin' then
			if arg.typ.builtin == 'bool' then
				printf('frombool(%s)', name)
			else
				printf('uintptr(%s)', name)
			end
		elseif is_pointer(arg.typ) then
			printf('uintptr(unsafe.Pointer(%s))', name)
		elseif kind == 'name' then
			-- FIXME(akavel): some named types may actually be bools
			printf('uintptr(%s)', name)
		else
			error("don't know how to convert kind to uintptr: "..kind.." in arg: "..name)
		end
	end
	printf(")\n")

	-- func body - return
	-- TODO(akavel): try to put in DB info when a func returns successfully and when it returns error,
	-- then behave appropriately here
	if f.ret.kind == 'builtin' and f.ret.builtin == 'void' then
		printf "\treturn lastErr\n"
	else
		printf("\treturn (%s)(r1), lastErr\n", format_type(f.ret))
	end

	printf("}\n\n")
end

function format_signature(f, err)
	local buf = Buf()
	buf:printf("(", f.name)
	for i, arg in ipairs(f.args) do
		if i > 1 then buf:printf(", ") end
		buf:printf("%s %s", named_arg(arg.name, i), format_type(arg.typ))
	end
	buf:printf ")"
	if f.ret.kind == 'builtin' and f.ret.builtin == 'void' then
		buf:printf(err and " error" or "")
	else
		buf:printf(err and " (%s, error)" or " %s", format_type(f.ret))
	end
	return buf:string()
end

function format_type(typ)
	if typ.kind == 'builtin' then
		local builtins = {int32='int32', int16='int16'}
		return assert(builtins[typ.builtin], 'unknown builtin: '..typ.builtin)
	elseif typ.kind == 'pointer' then
		local to = typ.to
		if to.kind == 'builtin' and to.builtin == 'void' then
			-- TODO(akavel): *byte or unsafe.Pointer ?
			return 'unsafe.Pointer'
		end
		return '*' .. format_type(typ.to)
	elseif typ.kind == 'name' then
		return upcase(typ.name)
	else
		error('unknown type kind: '..typ.kind)
	end
end

function is_pointer(typ)
	if typ.kind == 'pointer' then
		return true
	elseif typ.kind == 'name' then
		local target = assert(data[typ.name], 'name not found in input: '..typ.name)
		if target.nameKind ~= 'typedef' then
			return false
		end
		return is_pointer(target.typ)
	else
		return false
	end
end

function named_arg(s, i)
	return s or '_'..i
end

function upcase(s)
	local first, rest = s:sub(1,1), s:sub(2)
	if first == '_' then
		return 'X_' .. rest
	else
		return first:upper() .. rest
	end
end

function printf(fmt, ...)
	output:write(fmt:format(...))
end

function Buf()
	return setmetatable({}, {__index={
		printf = function(self, fmt, ...)
			self[#self+1] = fmt:format(...)
		end,
		string = function(self)
			return table.concat(self, '')
		end,
	}})
end

main(...)

