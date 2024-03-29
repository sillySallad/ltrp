local ltrp_base = (...):match("^(.-)[^%./\\]*$")
local function ltrprequire(name) return require(ltrp_base .. name) end

local list = ltrprequire "ltrp_list"

local lex = ltrprequire "ltrp_lexer"
local parse = ltrprequire "ltrp_parser"
local generate = ltrprequire "ltrp_generator"

local function compile(src)
	local tokens, le, ptokens = lex(src)
	if not tokens then
		return nil, le, "lexer", ptokens
	end
	local tree, pe, ptree = parse(tokens)
	if not tree then
		return nil, pe, "parser", ptree
	end
	local lua, ge, plua = generate(tree)
	if not lua then
		return nil, ge, "generator", plua
	end
	return lua
end

local function extendrequire()
	-- package.ltrppath = [[.\?.ltrp;.\?\init.ltrp]]
	package.ltrppath = package.path:gsub('%.lua', '.ltrp')
	table.insert(package.searchers or package.loaders, 2, function(name)
		local p,e = package.searchpath(name, package.ltrppath)
		if not p then
			return e
		end
		return function()
			local file = assert(io.open(p, 'r'))
			local src = assert(file:read '*a')
			file:close()
			local lua, err = compile(src)
			if not lua then
				error(("%s:\n%s"):format(p, err), 2)
			end
			local ret, err = load(lua, p, 't')
			if LTRP_DEBUG or not ret then
				print(p)
				print(lua)
			end
			if not ret then
				error(err)
			end
			ret = ret() or true
			package.loaded[name] = ret
			return ret
		end
	end)
end

return {
	compile = compile,
	extendrequire = extendrequire,
}

