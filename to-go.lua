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

	-- emit common preamble
	printf [[
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

]]

	-- emit entities
	for name, entity in pairs(input) do
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
				if v.ival then
					printf("\t%s %s = %d\n", upcase(v.name), upcase(entity.name), v.ival)
				else
					printf("\t// FIXME: %s %s = %s\n", v.name, entity.name, v.val)
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
		if kind == 'name' or kind == 'builtin' then
			if arg.typ.builtin == 'bool' then
				printf('frombool(%s)', name)
			else
				-- FIXME(akavel): some named types may actually be pointers (or bools) -- e.g. LPCWSTR
				printf('uintptr(%s)', name)
			end
		elseif kind == 'pointer' then
			printf('uintptr(unsafe.Pointer(%s))', name)
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
	io.write(fmt:format(...))
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

main()

