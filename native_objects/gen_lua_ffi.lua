-- Copyright (c) 2010 by Robert G. Jakabosky <bobby@neoawareness.com>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.


--
-- build LuaJIT FFI bindings
--

local ffi_helper_types = [[
#if LUAJIT_FFI
typedef int (*ffi_export_func_t)(void);
typedef struct ffi_export_symbol {
	const char *name;
	union {
	void               *data;
	ffi_export_func_t  func;
	} sym;
} ffi_export_symbol;
#endif
]]

local objHelperFunc = [[
#if LUAJIT_FFI

/* nobj_ffi_support_enabled_hint should be set to 1 when FFI support is enabled in at-least one
 * instance of a LuaJIT state.  It should never be set back to 0. */
static int nobj_ffi_support_enabled_hint = 0;
static const char nobj_ffi_support_key[] = "LuaNativeObject_FFI_SUPPORT";
static const char nobj_check_ffi_support_code[] =
"local stat, ffi=pcall(require,\"ffi\")\n" /* try loading LuaJIT`s FFI module. */
"if not stat then return false end\n"
"return true\n";

static int nobj_check_ffi_support(lua_State *L) {
	int rc;
	int err;

	/* check if ffi test has already been done. */
	lua_pushstring(L, nobj_ffi_support_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if(!lua_isnil(L, -1)) {
		rc = lua_toboolean(L, -1);
		lua_pop(L, 1);
		return rc; /* return results of previous check. */
	}
	lua_pop(L, 1); /* pop nil. */

	err = luaL_loadbuffer(L, nobj_check_ffi_support_code,
		sizeof(nobj_check_ffi_support_code) - 1, nobj_ffi_support_key);
	if(0 == err) {
		err = lua_pcall(L, 0, 1, 0);
	}
	if(err) {
		const char *msg = "<err not a string>";
		if(lua_isstring(L, -1)) {
			msg = lua_tostring(L, -1);
		}
		printf("Error when checking for FFI-support: %s\n", msg);
		lua_pop(L, 1); /* pop error message. */
		return 0;
	}
	/* check results of test. */
	rc = lua_toboolean(L, -1);
	lua_pop(L, 1); /* pop results. */
		/* cache results. */
	lua_pushstring(L, nobj_ffi_support_key);
	lua_pushboolean(L, rc);
	lua_rawset(L, LUA_REGISTRYINDEX);

	/* turn-on hint that there is FFI code enabled. */
	if(rc) {
		nobj_ffi_support_enabled_hint = 1;
	}

	return rc;
}

static int nobj_try_loading_ffi(lua_State *L, const char *ffi_mod_name,
		const char *ffi_init_code, const ffi_export_symbol *ffi_exports, int priv_table)
{
	int err;

	/* export symbols to priv_table. */
	while(ffi_exports->name != NULL) {
		lua_pushstring(L, ffi_exports->name);
		lua_pushlightuserdata(L, ffi_exports->sym.data);
		lua_settable(L, priv_table);
		ffi_exports++;
	}
	err = luaL_loadbuffer(L, ffi_init_code, strlen(ffi_init_code), ffi_mod_name);
	if(0 == err) {
		lua_pushvalue(L, -2); /* dup C module's table. */
		lua_pushvalue(L, priv_table); /* move priv_table to top of stack. */
		lua_remove(L, priv_table);
		lua_pushvalue(L, LUA_REGISTRYINDEX);
		err = lua_pcall(L, 3, 0, 0);
	}
	if(err) {
		const char *msg = "<err not a string>";
		if(lua_isstring(L, -1)) {
			msg = lua_tostring(L, -1);
		}
		printf("Failed to install FFI-based bindings: %s\n", msg);
		lua_pop(L, 1); /* pop error message. */
	}
	return err;
}
#endif
]]

local module_init_src = [[
#if LUAJIT_FFI
	if(nobj_check_ffi_support(L)) {
		nobj_try_loading_ffi(L, "${module_c_name}", ${module_c_name}_ffi_lua_code,
			${module_c_name}_ffi_export, priv_table);
	}
#endif
]]

local submodule_init_src = [[
#if ${module_c_name}_${object_name}_LUAJIT_FFI
	if(nobj_check_ffi_support(L)) {
		nobj_try_loading_ffi(L, "${module_c_name}_${object_name}",
			${module_c_name}_${object_name}_ffi_lua_code,
			${module_c_name}_${object_name}_ffi_export, priv_table);
	}
#endif
]]

--
-- FFI templates
--
local ffi_helper_code = [===[
local ffi=require"ffi"
local function ffi_safe_load(name, global)
	local stat, C = pcall(ffi.load, name, global)
	if not stat then return nil, C end
	if global then return ffi.C end
	return C
end
local function ffi_load(name, global)
	return assert(ffi_safe_load(name, global))
end

local error = error
local type = type
local tonumber = tonumber
local tostring = tostring
local rawset = rawset
local setmetatable = setmetatable
local p_config = package.config
local p_cpath = package.cpath

local ffi_load_cmodule

-- try to detect luvit.
if p_config == nil and p_cpath == nil then
	ffi_load_cmodule = function(name, global)
		for path,module in pairs(package.loaded) do
			if type(module) == 'string' and path:match("zmq") then
				local C, err = ffi_safe_load(path .. '.luvit', global)
				-- return opened library
				if C then return C end
			end
		end
		error("Failed to find: " .. name)
	end
else
	ffi_load_cmodule = function(name, global)
		local dir_sep = p_config:sub(1,1)
		local path_sep = p_config:sub(3,3)
		local path_mark = p_config:sub(5,5)
		local path_match = "([^" .. path_sep .. "]*)" .. path_sep
		-- convert dotted name to directory path.
		name = name:gsub('%.', dir_sep)
		-- try each path in search path.
		for path in p_cpath:gmatch(path_match) do
			local fname = path:gsub(path_mark, name)
			local C, err = ffi_safe_load(fname, global)
			-- return opened library
			if C then return C end
		end
		error("Failed to find: " .. name)
	end
end

local _M, _priv, reg_table = ...
local REG_OBJECTS_AS_GLOBALS = false

local OBJ_UDATA_FLAG_OWN		= 1

local function ffi_safe_cdef(block_name, cdefs)
	local fake_type = "struct sentinel_" .. block_name .. "_ty"
	local stat, size = pcall(ffi.sizeof, fake_type)
	if stat and size > 0 then
		-- already loaded this cdef block
		return
	end
	cdefs = fake_type .. "{ int a; int b; int c; };" .. cdefs
	return ffi.cdef(cdefs)
end

ffi_safe_cdef("LuaNativeObjects", [[

typedef struct obj_type obj_type;

typedef void (*base_caster_t)(void **obj);

typedef void (*dyn_caster_t)(void **obj, obj_type **type);

struct obj_type {
	dyn_caster_t    dcaster;  /**< caster to support casting to sub-objects. */
	int32_t         id;       /**< type's id. */
	uint32_t        flags;    /**< type's flags (weak refs) */
	const char      *name;    /**< type's object name. */
};

typedef struct obj_base {
	int32_t        id;
	base_caster_t  bcaster;
} obj_base;

typedef struct obj_udata {
	void     *obj;
	uint32_t flags;  /**< lua_own:1bit */
} obj_udata;

int memcmp(const void *s1, const void *s2, size_t n);

]])

local function obj_ptr_to_id(ptr)
	return tonumber(ffi.cast('uintptr_t', ptr))
end

local function obj_to_id(ptr)
	return tonumber(ffi.cast('uintptr_t', ffi.cast('void *', ptr)))
end

local function register_default_constructor(_pub, obj_name, constructor)
	local obj_pub = _pub[obj_name]
	if type(obj_pub) == 'table' then
		-- copy table since it might have a locked metatable
		local new_pub = {}
		for k,v in pairs(obj_pub) do
			new_pub[k] = v
		end
		setmetatable(new_pub, { __call = function(t,...)
			return constructor(...)
		end,
		__metatable = false,
		})
		obj_pub = new_pub
	else
		obj_pub = constructor
	end
	_pub[obj_name] = obj_pub
	_M[obj_name] = obj_pub
	if REG_OBJECTS_AS_GLOBALS then
		_G[obj_name] = obj_pub
	end
end
]===]

-- templates for typed *_check/*_delete/*_push functions
local ffi_obj_type_check_delete_push = {
['simple'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	ffi_safe_cdef("${object_name}_simple_wrapper", [=[
		struct ${object_name}_t {
			const ${object_name} _wrapped_val;
		};
		typedef struct ${object_name}_t ${object_name}_t;
	]=])

	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name}_t")
	_type_names.${object_name} = tostring(obj_ctype)
	local obj_flags = {}

	function obj_type_${object_name}_check(obj)
		return obj._wrapped_val
	end

	function obj_type_${object_name}_delete(obj)
		local id = obj_to_id(obj)
		local valid = obj_flags[id]
		if not valid then return nil end
		local val = obj._wrapped_val
		obj_flags[id] = nil
		return val
	end

	function obj_type_${object_name}_push(val)
		local obj = obj_ctype(val)
		local id = obj_to_id(obj)
		obj_flags[id] = true
		return obj
	end

	function obj_mt:__tostring()
		return "${object_name}: " .. tostring(self._wrapped_val)
	end

	function obj_mt.__eq(val1, val2)
		if not ffi.istype("${object_name}_t", val2) then return false end
		return (val1._wrapped_val == val2._wrapped_val)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(obj)
		if ffi.istype("${object_name}_t", obj) then return obj._wrapped_val end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr)
		return obj_type_${object_name}_push(ffi.cast("${object_name} *", ptr)[0])
	end

end

]],
['simple ptr'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name} *")
	local obj_flags = {}

	function obj_type_${object_name}_check(ptr)
		return ptr
	end

	function obj_type_${object_name}_delete(ptr)
		local id = obj_ptr_to_id(ptr)
		local flags = obj_flags[id]
		if not flags then return ptr end
		ffi.gc(ptr, nil)
		obj_flags[id] = nil
		return ptr
	end

	if obj_mt.__gc then
		-- has __gc metamethod
		function obj_type_${object_name}_push(ptr)
			local id = obj_ptr_to_id(ptr)
			obj_flags[id] = true
			return ffi.gc(ptr, obj_mt.__gc)
		end
	else
		-- no __gc metamethod
		function obj_type_${object_name}_push(ptr)
			return ptr
		end
	end

	function obj_mt:__tostring()
		local id = obj_ptr_to_id(self)
		return "${object_name}: " .. tostring(id)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(ptr)
		if ffi.istype("${object_name} *", ptr) then return ptr end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr)
		return obj_type_${object_name}_push(ffi.cast("${object_name} *", ptr)[0])
	end

end

]],
['embed'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name}")
	local ${object_name}_sizeof = ffi.sizeof"${object_name}"

	function obj_type_${object_name}_check(obj)
		return obj
	end

	function obj_type_${object_name}_delete(obj)
		return obj
	end

	function obj_type_${object_name}_push(obj)
		return obj
	end

	function obj_mt:__tostring()
		return "${object_name}: " .. tostring(ffi.cast('void *', self))
	end

	function obj_mt.__eq(val1, val2)
		if not ffi.istype("${object_name}", val2) then return false end
		assert(ffi.istype("${object_name}", val1), "expected ${object_name}")
		return (C.memcmp(val1, val2, ${object_name}_sizeof) == 0)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(obj)
		if ffi.istype("${object_name}", obj) then return obj end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr)
		local obj = ffi.new("${object_name}")
		ffi.copy(obj, ptr, ${object_name}_sizeof);
		return obj
	end

end

]],
['object id'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	ffi_safe_cdef("${object_name}_simple_wrapper", [=[
		struct ${object_name}_t {
			const ${object_name} _wrapped_val;
		};
		typedef struct ${object_name}_t ${object_name}_t;
	]=])

	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name}_t")
	local obj_flags = {}

	function obj_type_${object_name}_check(obj)
		return obj._wrapped_val
	end

	function obj_type_${object_name}_delete(obj)
		local id = obj_ptr_to_id(obj)
		local flags = obj_flags[id]
		local val = obj._wrapped_val
		if not flags then return nil, 0 end
		obj_flags[id] = nil
		return val, flags
	end

	function obj_type_${object_name}_push(val, flags)
		local obj = obj_ctype(val)
		local id = obj_ptr_to_id(obj)
		obj_flags[id] = flags
		return obj
	end

	function obj_mt:__tostring()
		return "${object_name}: " .. tostring(self._wrapped_val)
	end

	function obj_mt.__eq(val1, val2)
		if not ffi.istype("${object_name}_t", val2) then return false end
		return (val1._wrapped_val == val2._wrapped_val)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(obj)
		if ffi.istype("${object_name}_t", obj) then return obj._wrapped_val end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr, flags)
		return obj_type_${object_name}_push(ffi.cast('uintptr_t',ptr), flags)
	end

end

]],
['generic'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name} *")
	_type_names.${object_name} = tostring(obj_ctype)
	local obj_flags = {}

	function obj_type_${object_name}_check(ptr)
		-- if ptr is nil or is the correct type, then just return it.
		if not ptr or ffi.istype("${object_name} *", ptr) then return ptr end
		-- check if it is a compatible type.
		local ctype = tostring(ffi.typeof(ptr))
		if _obj_subs.${object_name}[ctype] then
			return ffi.cast("${object_name} *", ptr)
		end
		return error("Expected '${object_name} *'", 2)
	end

	function obj_type_${object_name}_delete(ptr)
		local id = obj_ptr_to_id(ptr)
		local flags = obj_flags[id]
		if not flags then return nil, 0 end
		ffi.gc(ptr, nil)
		obj_flags[id] = nil
		return ptr, flags
	end

	function obj_type_${object_name}_push(ptr, flags)
		if flags ~= 0 then
			local id = obj_ptr_to_id(ptr)
			obj_flags[id] = flags
			ffi.gc(ptr, obj_mt.__gc)
		end
		return ptr
	end

	function obj_mt:__tostring()
		local id = obj_ptr_to_id(self)
		return "${object_name}: " .. tostring(id)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(ptr)
		if ffi.istype("${object_name} *", ptr) then return ptr end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr, flags)
		return obj_type_${object_name}_push(ffi.cast('${object_name} *',ptr), flags)
	end

end

]],
['generic_weak'] = [[
local obj_type_${object_name}_check
local obj_type_${object_name}_delete
local obj_type_${object_name}_push

do
	local obj_mt = _priv.${object_name}
	local obj_type = obj_mt['.type']
	local obj_ctype = ffi.typeof("${object_name} *")
	_type_names.${object_name} = tostring(obj_ctype)
	local objects = setmetatable({}, {__mode = "v"})
	local obj_flags = {}

	function obj_type_${object_name}_check(ptr)
		-- if ptr is nil or is the correct type, then just return it.
		if not ptr or ffi.istype("${object_name} *", ptr) then return ptr end
		-- check if it is a compatible type.
		local ctype = tostring(ffi.typeof(ptr))
		if _obj_subs.${object_name}[ctype] then
			return ffi.cast("${object_name} *", ptr)
		end
		return error("Expected '${object_name} *'", 2)
	end

	function obj_type_${object_name}_delete(ptr)
		local id = obj_ptr_to_id(ptr)
		local flags = obj_flags[id]
		if not flags then return nil, 0 end
		ffi.gc(ptr, nil)
		obj_flags[id] = nil
		return ptr, flags
	end

	function obj_type_${object_name}_push(ptr, flags)
		local id = obj_ptr_to_id(ptr)
		-- check weak refs
		local old_ptr = objects[id]
		if old_ptr then return old_ptr end
		if flags ~= 0 then
			obj_flags[id] = flags
			ffi.gc(ptr, obj_mt.__gc)
		end
		objects[id] = ptr
		return ptr
	end

	function obj_mt:__tostring()
		local id = obj_ptr_to_id(self)
		return "${object_name}: " .. tostring(id)
	end

	-- type checking function for C API.
	_priv[obj_type] = function(ptr)
		if ffi.istype("${object_name} *", ptr) then return ptr end
		return nil
	end
	-- push function for C API.
	reg_table[obj_type] = function(ptr, flags)
		return obj_type_${object_name}_push(ffi.cast('${object_name} *',ptr), flags)
	end

end

]],
}

local ffi_obj_metatype = {
['simple'] = "${object_name}_t",
['simple ptr'] = "${object_name}_t",
['embed'] = "${object_name}",
['object id'] = "${object_name}_t",
['generic'] = nil,
['generic_weak'] = "${object_name}",
}

local function get_var_name(var)
	local name = 'self'
	if not var.is_this then
		name = '${' .. var.name .. '}'
	end
	return name
end
local function unwrap_value(self, var)
	local name = get_var_name(var)
	return name .. ' = ' .. name .. '._wrapped_val\n'
end
local function no_wrapper(self, var) return '\n' end
local ffi_obj_type_check = {
['simple'] = unwrap_value,
['simple ptr'] = no_wrapper,
['embed'] = no_wrapper,
['object id'] = unwrap_value,
['generic'] = no_wrapper,
['generic_weak'] = no_wrapper,
}

-- module template
local ffi_module_template = [[
local _pub = {}
local _meth = {}
local _push = {}
local _obj_subs = {}
local _type_names = {}
for obj_name,mt in pairs(_priv) do
	if type(mt) == 'table' then
		_obj_subs[obj_name] = {}
		if mt.__index then
			_meth[obj_name] = mt.__index
		end
	end
end
for obj_name,pub in pairs(_M) do
	_pub[obj_name] = pub
end

]]

local ffi_submodule_template = ffi_module_template

-- re-map meta-methods.
local lua_meta_methods = {
__str__ = '__tostring',
__eq__ = '__eq',
delete = '__gc',
-- Lua metamethods
__add = '__add',
__sub = '__sub',
__mul = '__mul',
__div = '__div',
__mod = '__mod',
__pow = '__pow',
__unm = '__unm',
__len = '__len',
__concat = '__concat',
__eq = '__eq',
__lt = '__lt',
__le = '__le',
__gc = '__gc',
__tostring = '__tostring',
__index = '__index',
__newindex = '__newindex',
}

local function dump_lua_code_to_c_str(code)
	-- make Lua code C-safe
	code = code:gsub('[\n"\\%z]', {
	['\n'] = "\\n\"\n\"",
	['\r'] = "\\r",
	['"'] = [[\"]],
	['\\'] = [[\\]],
	['\0'] = [[\0]],
	})
	return '"' .. code .. '";'
end

local function gen_if_defs_code(rec)
	if rec.ffi_if_defs then return end
	-- generate if code for if_defs.
	local if_defs = rec.if_defs
	local endif = 'end\n'
	if type(if_defs) == 'string' then
		if_defs = "if (" .. if_defs .. ') then\n'
	elseif type(if_defs) == 'table' then
		if_defs = "if (" .. table.concat(if_defs," or ") .. ') then\n'
	else
		if_defs = ''
		endif = ''
	end
	rec.ffi_if_defs = if_defs
	rec.ffi_endif = endif
end

local function reg_object_function(self, func, object)
	local ffi_table = '_meth'
	local name = func.name
	local reg_list
	-- check if this is object free/destructure method
	if func.is_destructor then
		if func._is_hidden then
			-- don't register '__gc' metamethods as a public object method.
			return '_priv.${object_name}.', '_priv', '__gc'
		end
	elseif func.is_constructor then
		ffi_table = '_pub'
	elseif func._is_meta_method then
		ffi_table = '_priv'
		-- use Lua's __* metamethod names
		name = lua_meta_methods[func.name]
	elseif func._is_method then
		ffi_table = '_meth'
	else
		ffi_table = '_pub'
	end
	local obj_table = ffi_table .. '.${object_name}.'
	if object._rec_type == 'c_module' then
		obj_table = '_M.'
	end
	return obj_table, ffi_table, name
end

local function add_source(rec, part, src, pos)
	return rec:insert_record(c_source(part)(src), 1)
end

print"============ Lua bindings ================="
-- do some pre-processing of objects.
process_records{
object = function(self, rec, parent)
	if rec.is_package then return end
	local ud_type = rec.userdata_type
	if not rec.no_weak_ref then
		ud_type = ud_type .. '_weak'
	end
	rec.ud_type = ud_type
	-- create _ffi_check_fast function
	rec._ffi_check_fast = ffi_obj_type_check[ud_type]
end,
}

local parsed = process_records{
_modules_out = {},
_includes = {},

-- record handlers
c_module = function(self, rec, parent)
	local module_c_name = rec.name:gsub('(%.)','_')
	rec:add_var('module_c_name', module_c_name)
	rec:add_var('module_name', rec.name)
	rec:add_var('object_name', rec.name)
	self._cur_module = rec
	self._modules_out[rec.name] = rec
	add_source(rec, "typedefs", ffi_helper_types, 1)
	-- hide_meta_info?
	if rec.hide_meta_info == nil then rec.hide_meta_info = true end
	-- luajit_ffi?
	rec:insert_record(define("LUAJIT_FFI")(rec.luajit_ffi and 1 or 0), 1)
	-- use_globals?
	rec:write_part("ffi_obj_type",
		{'REG_OBJECTS_AS_GLOBALS = ',(rec.use_globals and 'true' or 'false'),'\n'})
	-- luajit_ffi_load_cmodule?
	if rec.luajit_ffi_load_cmodule then
		local global = 'false'
		if rec.luajit_ffi_load_cmodule == 'global' then
			global = 'true'
		end
		rec:write_part("ffi_typedef", {[[
local C = ffi_load_cmodule("${module_c_name}", ]], global ,[[)

]]})
	end
	-- where we want the module function registered.
	rec.functions_regs = 'function_regs'
	rec.methods_regs = 'function_regs'
	-- symbols to export to FFI
	rec:write_part("ffi_export", {
		'#if LUAJIT_FFI\n',
		'static const ffi_export_symbol ${module_c_name}_ffi_export[] = {\n'})
	-- start two ffi.cdef code blocks (one for typedefs and one for function prototypes).
	rec:write_part("ffi_typedef", {
	'ffi.cdef[[\n'
	})
	rec:write_part("ffi_cdef", {
	'ffi.cdef[[\n'
	})
	-- add module's FFI template
	rec:write_part("ffi_obj_type", {
		ffi_module_template,
		'\n'
	})
end,
c_module_end = function(self, rec, parent)
	self._cur_module = nil
	-- end list of FFI symbols
	rec:write_part("ffi_export", {
	'  {NULL, { .data = NULL } }\n',
	'};\n',
	'#endif\n\n'
	})
	add_source(rec, "luaopen_defs", rec:dump_parts{ "ffi_export" }, 1)
	-- end ffi.cdef code blocks
	rec:write_part("ffi_typedef", {
	'\n]]\n\n'
	})
	rec:write_part("ffi_cdef", {
	'\n]]\n\n'
	})

	-- add module init code for FFI support
	local part = "module_init_src"
	rec:write_part(part, module_init_src)
	rec:vars_part(part)
	add_source(rec, part, rec:dump_parts(part))
	-- FFI helper C code.
	add_source(rec, "helper_funcs", objHelperFunc)
	-- encode luajit ffi code
	if rec.luajit_ffi then
		local ffi_code = ffi_helper_code .. rec:dump_parts{
			"ffi_typedef", "ffi_cdef", "ffi_obj_type", "ffi_import", "ffi_src",
			"ffi_metas_regs", "ffi_extends"
		}
		rec:write_part("ffi_code",
		{'\nstatic const char ${module_c_name}_ffi_lua_code[] = ', dump_lua_code_to_c_str(ffi_code)
		})
		rec:vars_part("ffi_code")
		add_source(rec, "extra_code", rec:dump_parts("ffi_code"))
	end
end,
error_code = function(self, rec, parent)
	rec:add_var('object_name', rec.name)
	rec:write_part("ffi_typedef", {
		'typedef ', rec.c_type, ' ', rec.name, ';\n\n',
	})
	-- add variable for error string
	rec:write_part("ffi_src", {
		'local function ',rec.func_name,'(err)\n',
		'  local err_str\n'
		})
end,
error_code_end = function(self, rec, parent)
	-- return error string.
	rec:write_part("ffi_src", [[
	return err_str
end

]])

	-- don't generate FFI bindings
	if self._cur_module.ffi_manual_bindings then return end

	-- copy generated FFI bindings to parent
	local ffi_parts = { "ffi_typedef", "ffi_cdef", "ffi_src" }
	rec:vars_parts(ffi_parts)
	parent:copy_parts(rec, ffi_parts)
end,
object = function(self, rec, parent)
	rec:add_var('object_name', rec.name)
	-- make luaL_reg arrays for this object
	if not rec.is_package then
		-- where we want the module function registered.
		rec.methods_regs = 'methods_regs'
		-- FFI typedef
		local ffi_type = rec.ffi_type or 'struct ${object_name}'
		rec:write_part("ffi_typedef", {
			'typedef ', ffi_type, ' ${object_name};\n',
		})
	elseif rec.is_meta then
		-- where we want the module function registered.
		rec.methods_regs = 'methods_regs'
	end
	rec.functions_regs = 'pub_funcs_regs'
	-- FFI code
	rec:write_part("ffi_src",
		{'\n-- Start "${object_name}" FFI interface\n'})
	-- Sub-module FFI code
	if rec.register_as_submodule then
		-- luajit_ffi?
		rec:write_part("defines",
			{'#define ${module_c_name}_${object_name}_LUAJIT_FFI ',(rec.luajit_ffi and 1 or 0),'\n'})
		-- symbols to export to FFI
		rec:write_part("ffi_export",
			{'\nstatic const ffi_export_symbol ${module_c_name}_${object_name}_ffi_export[] = {\n'})
		-- start two ffi.cdef code blocks (one for typedefs and one for function prototypes).
		rec:write_part("ffi_typedef", {
		'ffi.cdef[[\n'
		})
		rec:write_part("ffi_cdef", {
		'ffi.cdef[[\n'
		})
		-- add module's FFI template
		rec:write_part("ffi_obj_type", {
			ffi_submodule_template,
			'\n'
		})
	end
end,
object_end = function(self, rec, parent)
	-- check for dyn_caster
	local dyn_caster = ''
	if rec.has_dyn_caster then
		dyn_caster = "  local cast_obj = " .. rec.has_dyn_caster.dyn_caster_name .. [[(obj)
  if cast_obj then return cast_obj end
]]
	end
	-- register metatable for FFI cdata type.
	if not rec.is_package then
		-- create FFI check/delete/push functions
		rec:write_part("ffi_obj_type", {
			rec.ffi_custom_delete_push or ffi_obj_type_check_delete_push[rec.ud_type],
			'\n'
		})
		local c_metatype = ffi_obj_metatype[rec.ud_type]
		if c_metatype then
			rec:write_part("ffi_src",{
				'_push.${object_name} = obj_type_${object_name}_push\n',
				'ffi.metatype("',c_metatype,'", _priv.${object_name})\n',
		})
		end
	end
	-- end object's FFI source
	rec:write_part("ffi_src",
		{'-- End "${object_name}" FFI interface\n\n'})

	if rec.register_as_submodule then
		if not (self._cur_module.luajit_ffi and rec.luajit_ffi) then
			return
		end
		-- Sub-module FFI code
		-- end list of FFI symbols
		rec:write_part("ffi_export", {
		'  {NULL, { .data = NULL } }\n',
		'};\n\n'
		})
		-- end ffi.cdef code blocks
		rec:write_part("ffi_typedef", {
		'\n]]\n\n'
		})
		rec:write_part("ffi_cdef", {
		'\n]]\n\n'
		})
		local ffi_code = ffi_helper_code .. rec:dump_parts{
			"ffi_typedef", "ffi_cdef", "ffi_obj_type", "ffi_import", "ffi_src",
			"ffi_metas_regs", "ffi_extends"
		}
		rec:write_part("ffi_code",
		{'\nstatic const char ${module_c_name}_${object_name}_ffi_lua_code[] = ',
			dump_lua_code_to_c_str(ffi_code)
		})
		-- copy ffi_code to partent
		rec:vars_parts{ "ffi_code", "ffi_export" }
		parent:copy_parts(rec, { "ffi_code" })
		add_source(rec, "luaopen_defs", rec:dump_parts{ "ffi_export" }, 1)
		-- add module init code for FFI support
		local part = "module_init_src"
		rec:write_part(part, submodule_init_src)
		rec:vars_part(part)
		add_source(rec, part, rec:dump_parts(part))
	else
		-- apply variables to FFI parts
		local ffi_parts = { "ffi_obj_type", "ffi_export" }
		rec:vars_parts(ffi_parts)
		-- copy parts to parent
		parent:copy_parts(rec, ffi_parts)

		-- don't generate FFI bindings
		if self._cur_module.ffi_manual_bindings then return end

		-- copy generated FFI bindings to parent
		local ffi_parts = { "ffi_typedef", "ffi_cdef", "ffi_import", "ffi_src",
			"ffi_metas_regs", "ffi_extends"
		}
		rec:vars_parts(ffi_parts)
		parent:copy_parts(rec, ffi_parts)
	end

end,
callback_state = function(self, rec, parent)
end,
callback_state_end = function(self, rec, parent)
end,
include = function(self, rec, parent)
end,
define = function(self, rec, parent)
end,
extends = function(self, rec, parent)
	assert(not parent.is_package, "A Package can't extend anything: package=" .. parent.name)
	local base = rec.base
	local base_cast = 'NULL'
	if base == nil then return end
	-- add sub-classes to base class list of subs.
	parent:write_part("ffi_extends",
		{'-- add sub-class to base classes list of subs\n',
		 '_obj_subs.', base.name, '[_type_names.${object_name}] = true\n',
		})
	-- add methods/fields/constants from base object
	parent:write_part("ffi_src",
		{'-- Clear out methods from base class, to allow ffi-based methods from base class\n'})
	parent:write_part("ffi_extends",
		{'-- Copy ffi methods from base class to sub class.\n'})
	for name,val in pairs(base.name_map) do
		-- make sure sub-class has not override name.
		if parent.name_map[name] == nil then
			parent.name_map[name] = val
			if val._is_method and not val.is_constructor then
				gen_if_defs_code(val)
				-- register base class's method with sub class
				local obj_table, ffi_table, name = reg_object_function(self, val, parent)
				-- write ffi code to remove registered base class method.
				parent:write_part("ffi_src",
				{obj_table, name, ' = nil\n'})
				-- write ffi code to copy method from base class.
				parent:write_part("ffi_extends",
				{val.ffi_if_defs, obj_table,name,' = ',
					ffi_table,'.',base.name,'.',name,'\n', val.ffi_endif})
			end
		end
	end
end,
extends_end = function(self, rec, parent)
end,
callback_func = function(self, rec, parent)
end,
callback_func_end = function(self, rec, parent)
end,
dyn_caster = function(self, rec, parent)
	local vtab = rec.ffi_value_table or ''
	if vtab ~= '' then
		vtab = '_pub.' .. vtab .. '.'
	end
	rec.dyn_caster_name = 'dyn_caster_' .. parent.name
	-- generate lookup table for switch based caster.
	if rec.caster_type == 'switch' then
		local lookup_table = { "local dyn_caster_${object_name}_lookup = {\n" }
		local selector = ''
		if rec.value_field then
			selector = 'obj.' .. rec.value_field
		elseif rec.value_function then
			selector = "C." .. rec.value_function .. '(obj)'
		else
			error("Missing switch value for dynamic caster.")
		end
		rec:write_part('src', {
			'  local sub_type = dyn_caster_${object_name}_lookup[', selector, ']\n',
			'  local type_push = _push[sub_type or 0]\n',
			'  if type_push then return type_push(obj) end\n',
			'  return nil\n',
		})
		-- add cases for each sub-object type.
		for val,sub in pairs(rec.value_map) do
			lookup_table[#lookup_table + 1] = '[' .. vtab .. val .. '] = "' ..
				sub._obj_type_name .. '",\n'
		end
		lookup_table[#lookup_table + 1] = '}\n\n'
		parent:write_part("ffi_obj_type", lookup_table)
	end
end,
dyn_caster_end = function(self, rec, parent)
	-- append custom dyn caster code
	parent:write_part("ffi_obj_type",
		{"local function dyn_caster_${object_name}(obj)\n", rec:dump_parts{ "src" }, "end\n\n" })
end,
c_function = function(self, rec, parent)
	rec:add_var('object_name', parent.name)
	rec:add_var('function_name', rec.name)
	if rec.is_destructor then
		rec.__gc = true -- mark as '__gc' method
		-- check if this is the first destructor.
		if not parent.has_default_destructor then
			parent.has_default_destructor = rc
			rec.is__default_destructor = true
		end
	end
	-- generate if code for if_defs.
	gen_if_defs_code(rec)

	-- register method/function with object.
	local obj_table, ffi_table, name = reg_object_function(self, rec, parent)
	rec.obj_table = obj_table
	rec.ffi_table = ffi_table
	rec.ffi_reg_name = name

	-- generate FFI function
	rec:write_part("ffi_pre",
	{'-- method: ', name, '\n', rec.ffi_if_defs,
		'function ',obj_table, name, '(',rec.ffi_params,')\n'})
end,
c_function_end = function(self, rec, parent)
	-- don't generate FFI bindings
	if self._cur_module.ffi_manual_bindings then return end

	-- check if function has FFI support
	local ffi_src = rec:dump_parts("ffi_src")
	if rec.no_ffi or #ffi_src == 0 then return end

	-- generate if code for if_defs.
	local endif = '\n'
	if rec.if_defs then
		endif = 'end\n\n'
	end

	-- end Lua code for FFI function
	local ffi_parts = {"ffi_temps", "ffi_pre", "ffi_src", "ffi_post"}
	local ffi_return = rec:dump_parts("ffi_return")
	-- trim last ', ' from list of return values.
	ffi_return = ffi_return:gsub(", $","")
	rec:write_part("ffi_post",
		{'  return ', ffi_return,'\n',
		 'end\n', rec.ffi_endif})

	-- check if this is the default constructor.
	if rec.is_default_constructor then
		rec:write_part("ffi_post",
			{'register_default_constructor(_pub,"${object_name}",',
			rec.obj_table, rec.ffi_reg_name ,')\n'})
	end
	if rec.is__default_destructor and not rec._is_hidden and
			not self._cur_module.disable__gc and not parent.disable__gc then
		rec:write_part('ffi_post',
			{'_priv.${object_name}.__gc = ', rec.obj_table, rec.name, '\n'})
	end

	rec:vars_parts(ffi_parts)
	-- append FFI-based function to parent's FFI source
	local ffi_cdef = { "ffi_cdef" }
	rec:vars_parts(ffi_cdef)
	parent:write_part("ffi_cdef", rec:dump_parts(ffi_cdef))
	local temps = rec:dump_parts("ffi_temps")
	if #temps > 0 then
		parent:write_part("ffi_src", {"do\n", rec:dump_parts(ffi_parts), "end\n\n"})
	else
		parent:write_part("ffi_src", {rec:dump_parts(ffi_parts), "\n"})
	end
end,
c_source = function(self, rec, parent)
end,
ffi_export = function(self, rec, parent)
	parent:write_part("ffi_export",
		{'{ "', rec.name, '", { .data = ', rec.name, ' } },\n'})
end,
ffi_export_function = function(self, rec, parent)
	parent:write_part("ffi_export",
		{'{ "', rec.name, '", { .func = (ffi_export_func_t)', rec.name, ' } },\n'})
end,
ffi_source = function(self, rec, parent)
	parent:write_part(rec.part, rec.src)
	parent:write_part(rec.part, "\n")
end,
var_in = function(self, rec, parent)
	-- no need to add code for 'lua_State *' parameters.
	if rec.c_type == 'lua_State *' and rec.name == 'L' then return end
	-- register variable for code gen (i.e. so ${var_name} is replaced with true variable name).
	parent:add_rec_var(rec, rec.name, rec.is_this and 'self')
	-- don't generate code for '<any>' type parameters
	if rec.c_type == '<any>' then return end

	local var_type = rec.c_type_rec
	if rec.is_this and parent.__gc then
		if var_type.has_obj_flags then
			-- add flags ${var_name_flags} variable
			parent:add_rec_var(rec, rec.name .. '_flags')
			-- for garbage collect method, check the ownership flag before freeing 'this' object.
			parent:write_part("ffi_pre",
				{
				'  ', var_type:_ffi_delete(rec, true),
				'  if not ${',rec.name,'} then return end\n',
				})
		else
			-- for garbage collect method, check the ownership flag before freeing 'this' object.
			parent:write_part("ffi_pre",
				{
				'  ', var_type:_ffi_delete(rec, false),
				'  if not ${',rec.name,'} then return end\n',
				})
		end
	elseif var_type._rec_type ~= 'callback_func' then
		if var_type.lang_type == 'string' then
			-- add length ${var_name_len} variable
			parent:add_rec_var(rec, rec.name .. '_len')
		end
		-- check lua value matches type.
		local ffi_get
		if rec.is_optional then
			ffi_get = var_type:_ffi_opt(rec, rec.default)
		else
			ffi_get = var_type:_ffi_check(rec)
		end
		parent:write_part("ffi_pre",
			{'  ', ffi_get })
	end
end,
var_out = function(self, rec, parent)
	if rec.is_length_ref then
		return
	end
	local flags = false
	local var_type = rec.c_type_rec
	if var_type.has_obj_flags then
		if (rec.is_this or rec.own) then
			-- add flags ${var_name_flags} variable
			parent:add_rec_var(rec, rec.name .. '_flags')
			flags = '${' .. rec.name .. '_flags}'
			parent:write_part("ffi_pre",{
				'  local ',flags,' = OBJ_UDATA_FLAG_OWN\n'
			})
		else
			flags = "0"
		end
	end
	-- register variable for code gen (i.e. so ${var_name} is replaced with true variable name).
	parent:add_rec_var(rec, rec.name, rec.is_this and 'self')
	-- don't generate code for '<any>' type parameters
	if rec.c_type == '<any>' then
		if not rec.is_this then
			parent:write_part("ffi_pre",
				{'  local ${', rec.name, '}\n'})
		end
		parent:write_part("ffi_return", { "${", rec.name, "}, " })
		return
	end

	local var_type = rec.c_type_rec
	if var_type.lang_type == 'string' and rec.has_length then
		-- add length ${var_name_len} variable
		parent:add_rec_var(rec, rec.name .. '_len')
		-- the function's code will provide the string's length.
		parent:write_part("ffi_pre",{
			'  local ${', rec.name ,'_len} = 0\n'
		})
	end
	-- if the variable's type has a default value, then initialize the variable.
	local init = ''
	if var_type.default then
		init = ' = ' .. tostring(var_type.default)
	elseif var_type.userdata_type == 'embed' then
		init = ' = ffi.new("' .. var_type.name .. '")'
	end
	-- add C variable to hold value to be pushed.
	local ffi_unwrap = ''
	if rec.wrap == '&' then
		local temp_name = "${function_name}_" .. rec.name .. "_tmp"
		parent:write_part("ffi_temps",
			{'  local ', temp_name, ' = ffi.new("',rec.c_type,'[1]")\n'})
		parent:write_part("ffi_pre",
			{'  local ${', rec.name, '} = ', temp_name,'\n'})
		ffi_unwrap = '[0]'
	else
		parent:write_part("ffi_pre",
			{'  local ${', rec.name, '}',init,'\n'})
	end
	-- if this is a temp. variable, then we are done.
	if rec.is_temp then
		return
	end
	-- push Lua value onto the stack.
	local error_code = parent._has_error_code
	if error_code == rec then
		local err_type = error_code.c_type_rec
		-- if error_code is the first var_out, then push 'true' to signal no error.
		-- On error push 'false' and the error message.
		if rec._rec_idx == 1 then
			if err_type.ffi_is_error_check then
				parent:write_part("ffi_post", {
				'  -- check for error.\n',
				'  if ',err_type.ffi_is_error_check(error_code),' then\n',
				'    return nil, ', var_type:_ffi_push(rec, flags), '\n',
				'  end\n',
				})
				parent:write_part("ffi_return", { "true, " })
			end
		end
	elseif rec.no_nil_on_error ~= true and error_code then
		local err_type = error_code.c_type_rec
		-- return nil for this out variable, if there was an error.
		if err_type.ffi_is_error_check then
			parent:write_part("ffi_post", {
			'  if ',err_type.ffi_is_error_check(error_code),' then\n',
			'    return nil,', err_type:_ffi_push(error_code), '\n',
			'  end\n',
			})
		end
		parent:write_part("ffi_return", { var_type:_ffi_push(rec, flags, ffi_unwrap), ", " })
	elseif rec.is_error_on_null then
		-- if a function return NULL, then there was an error.
		parent:write_part("ffi_post", {
		'  if ',var_type.ffi_is_error_check(rec),' then\n',
		'    return nil, ', var_type:_ffi_push_error(rec), '\n',
		'  end\n',
		})
		parent:write_part("ffi_return", { var_type:_ffi_push(rec, flags, ffi_unwrap), ", " })
	else
		parent:write_part("ffi_return", { var_type:_ffi_push(rec, flags, ffi_unwrap), ", " })
	end
end,
cb_in = function(self, rec, parent)
end,
cb_out = function(self, rec, parent)
end,
}

print("Finished generating LuaJIT FFI bindings")

