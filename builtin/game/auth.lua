-- Minetest: builtin/auth.lua

--
-- Authentication handler
--

function core.string_to_privs(str, delim)
	assert(type(str) == "string")
	delim = delim or ','
	local privs = {}
	for _, priv in pairs(string.split(str, delim)) do
		privs[priv:trim()] = true
	end
	return privs
end

function core.privs_to_string(privs, delim)
	assert(type(privs) == "table")
	delim = delim or ','
	local list = {}
	for priv, bool in pairs(privs) do
		if bool then
			list[#list + 1] = priv
		end
	end
	return table.concat(list, delim)
end

assert(core.string_to_privs("a,b").b == true)
assert(core.privs_to_string({a=true,b=true}) == "a,b")

core.auth_file_path = core.get_worldpath().."/auth.txt"
core.auth_table = {}

local function read_auth_file()
	local newtable = {}
	local file, errmsg = io.open(core.auth_file_path, 'rb')
	if not file then
		core.log("info", core.auth_file_path.." could not be opened for reading ("..errmsg.."); assuming new world")
		return
	end
	for line in file:lines() do
		if line ~= "" then
			local fields = line:split(":", true)
			local name, password, privilege_string, last_login = unpack(fields)
			last_login = tonumber(last_login)
			if not (name and password and privilege_string) then
				error("Invalid line in auth.txt: "..dump(line))
			end
			local privileges = core.string_to_privs(privilege_string)
			newtable[name] = {password=password, privileges=privileges, last_login=last_login}
		end
	end
	io.close(file)
	core.auth_table = newtable
	core.notify_authentication_modified()
end

local function save_auth_file()
	local newtable = {}
	-- Check table for validness before attempting to save
	for name, stuff in pairs(core.auth_table) do
		assert(type(name) == "string")
		assert(name ~= "")
		assert(type(stuff) == "table")
		assert(type(stuff.password) == "string")
		assert(type(stuff.privileges) == "table")
		assert(stuff.last_login == nil or type(stuff.last_login) == "number")
	end
	local file, errmsg = io.open(core.auth_file_path, 'w+b')
	if not file then
		error(core.auth_file_path.." could not be opened for writing: "..errmsg)
	end
	for name, stuff in pairs(core.auth_table) do
		local priv_string = core.privs_to_string(stuff.privileges)
		local parts = {name, stuff.password, priv_string, stuff.last_login or ""}
		file:write(table.concat(parts, ":").."\n")
	end
	io.close(file)
end

core.builtin_auth_handler = {
	get_auth = function(name)
		assert(type(name) == "string")
		-- Figure out what password to use for a new player (singleplayer
		-- always has an empty password, otherwise use default, which is
		-- usually empty too)
		local new_password_hash = ""
		-- If not in authentication table, return nil
		if not core.auth_table[name] then
			return nil
		end
		-- Figure out what privileges the player should have.
		-- Take a copy of the privilege table
		local privileges = {}
		for priv, _ in pairs(core.auth_table[name].privileges) do
			privileges[priv] = true
		end
		-- If singleplayer, give all privileges except those marked as give_to_singleplayer = false
		if core.is_singleplayer() then
			for priv, def in pairs(core.registered_privileges) do
				if def.give_to_singleplayer then
					privileges[priv] = true
				end
			end
		-- For the admin, give everything
		elseif name == core.settings:get("name") then
			for priv, def in pairs(core.registered_privileges) do
				privileges[priv] = true
			end
		end
		-- All done
		return {
			password = core.auth_table[name].password,
			privileges = privileges,
			-- Is set to nil if unknown
			last_login = core.auth_table[name].last_login,
		}
	end,
	create_auth = function(name, password)
		core.log("action", "[AUTH] Adding entry for new player " .. name)
		assert(type(name) == "string")
		assert(type(password) == "string")
		core.auth_table[name] = {
			password = password,
			privileges = core.string_to_privs(core.settings:get("default_privs")),
			last_login = os.time(),
		}
	end,
	set_password = function(name, password)
		assert(type(name) == "string")
		assert(type(password) == "string")
		if not core.auth_table[name] then
			core.log("action", "[AUTH] Setting password for new player " .. name)
			core.builtin_auth_handler.create_auth(name, password)
		else
			core.log("action", "[AUTH] Setting password for existing player " .. name)
			core.auth_table[name].password = password
		end
		return true
	end,
	set_privileges = function(name, privileges)
		core.log("action", "[AUTH] Setting privileges for player " .. name)
		assert(type(name) == "string")
		assert(type(privileges) == "table")
		if not core.auth_table[name] then
			core.builtin_auth_handler.create_auth(name,
				core.get_password_hash(name,
					core.settings:get("default_password")))
		end
		core.auth_table[name].privileges = privileges
		core.notify_authentication_modified(name)
	end,
	reload = function()
		core.log("action", "[AUTH] Reading authentication data from disk")
		read_auth_file()
		return true
	end,
	commit = function()
		core.log("action", "[AUTH] Writing authentication data to disk")
		save_auth_file()
		return true
	end,
	record_login = function(name)
		assert(type(name) == "string")
		assert(core.auth_table[name]).last_login = os.time()
	end,
}

function core.register_authentication_handler(handler)
	if core.registered_auth_handler then
		error("Add-on authentication handler already registered by "..core.registered_auth_handler_modname)
	end
	core.registered_auth_handler = handler
	core.registered_auth_handler_modname = core.get_current_modname()
	handler.mod_origin = core.registered_auth_handler_modname
end

function core.get_auth_handler()
	return core.registered_auth_handler or core.builtin_auth_handler
end

local function auth_pass(name)
	return function(...)
		local auth_handler = core.get_auth_handler()
		if auth_handler[name] then
			return auth_handler[name](...)
		end
		return false
	end
end

core.set_player_password = auth_pass("set_password")
core.set_player_privs    = auth_pass("set_privileges")
core.auth_reload         = auth_pass("reload")
core.auth_commit         = auth_pass("commit")

core.auth_reload()

local record_login = auth_pass("record_login")

core.register_on_joinplayer(function(player)
	record_login(player:get_player_name())
end)

core.register_on_shutdown(function()
	core.auth_commit()
end)

core.register_on_prejoinplayer(function(name, ip)
	local auth = core.auth_table
	if auth[name] ~= nil then
		return
	end

	local name_lower = name:lower()
	for k in pairs(auth) do
		if k:lower() == name_lower then
			return string.format("\nYou can not register as '%s'! "..
					"Another player called '%s' is already registered. "..
					"Please check the spelling if it's your account "..
					"or use a different name.", name, k)
		end
	end
end)

-- Autosave
if not core.is_singleplayer() then
	local save_interval = 600
	local function auto_save()
		core.auth_commit()
		core.after(save_interval, auto_save)
	end
	core.after(save_interval, auto_save)
end
