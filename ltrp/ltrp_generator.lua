local list = require((...):match("^(.-)[^%./\\]*$") .. "ltrp_list")

local indentchar = "\t"
-- local function tempname(i) return i == 0 and "temp" or "tmp" .. i end
local function tempname(i) return "temp" .. i end

local function complain(ctx, token, msgptrn, ...)
	ctx.shared.errors(token:makecomplaint(msgptrn:format(...) .. ":"))
end

local function islid(t) -- literal or identifier
	return t.type == "identifier"
		or t.type == "number"
		or t.type == "string"
end

local function isstringandvalidident(t) return (t.type == "string" and t.value:find '^[%a_][%w_]*$') and true or false end

local function vartype(ctx, name)
	while ctx do
		if ctx.locals[name] then
			return true, "local"
		elseif ctx.globals[name] then
			return true, "global"
		else
			ctx = ctx.upctx
		end
	end
	return false, "neither"
end

local function Temp(ctx)
	local temp = ctx.temp
	ctx.temp = temp + 1
	return temp
end

local canbit = true
local bit53 = false
local jitbit = false

do
	if _VERSION == "Lua 5.3" then
		bit53 = true
	elseif jit then
		jitbit = true
	else
		canbit = false
	end
end

local function usebitop(ctx, op)
	if vartype(ctx, op) then return true end
	if not canbit then return false end
	if not bit53 then
		u = ctx.shared.usedbitops
		if not u[op] then
			local c = ctx
			while true do
				local uc = c.upctx
				if not uc or not uc.upctx then
					break
				end
				c = uc
			end
			c.params[op] = true
			c.locals[op] = true
		end
		u[op] = true
	end
	return true
end

local onetoonebinops = {
	['or'] = { symbol = "or", precedence = 1 },
	['and'] = { symbol = "and", precedence = 2 },
	concat = { symbol = "..", precedence = 8 },
	add = { symbol = "+", precedence = 9 },
	sub = { symbol = "-", precedence = 9 },
	mul = { symbol = "*", precedence = 10 },
	div = { symbol = "/", precedence = 10 },
	mod = { symbol = "%", precedence = 10 },
	-- unary: 11
	pow = { symbol = "^", precedence = 12 },
}

local bitops = {
	bor = { symbol = "|", func = "bor", precedence = 4 },
	bxor = { symbol = "~", func = "bxor", precedence = 5 },
	band = { symbol = "&", func = "band", precedence = 6 },
	lshift = { symbol = "<<", func = "lshift", precedence = 7 },
	rshift = { symbol = ">>", func = "rshift", precedence = 7 },
}

local compareops = {
	lt = { symbol = "<",  precedence = 3 },
	gt = { symbol = ">",  precedence = 3 },
	le = { symbol = "<=", precedence = 3 },
	ge = { symbol = ">=", precedence = 3 },
	ne = { symbol = "~=", precedence = 3 },
	eq = { symbol = "==", precedence = 3 },
	
	compare = { symbol = "<!=>", precedence = 3 },
}

local unaryops = {
	negate = { symbol = "-", precedence = 11 },
	bnot = { symbol = "~", precedence = 11 },
	['not'] = { symbol = "not ", precedence = 11 },
	len = { symbol = "#", precedence = 11 },
	
	unary = { symbol = "<~->", precedence = 11 },
}

local function getop(op) return onetoonebinops[op] or compareops[op] or bitops[op] or unaryops[op] end
local function lesserprecedence(node1, node2, le)
	local op1, op2 = node1.op, node2.op
	if node1.type == "identifier" then
		return false
	end
	local op_1 = getop(op1)
	local op_2 = getop(op2)
	assert(not op1 or op_1, op1)
	assert(not op2 or op_2, op2)
	if op1 and op_1 and op2 and op_2 then
		local p1, p2 = op_1.precedence, op_2.precedence
		return p1 < p2 or le and p1 <= p2
	end
end

local node

local function singlestatement(body, s, x, maxtemp)
	s '\n'
	s(x.indent)
	x.temp = 0
	s(node(body, x))
	return maxtemp < x.temp and x.temp or maxtemp
end

local function functionbody(body, ctx, params, vararg)
	local s = list()
	local x = {
		out = s,
		upctx = ctx,
		locals = {},
		globals = {},
		params = {},
		vararg = vararg or false,
		shared = ctx.shared,
		temp = 0,
		indent = ctx.indent and ctx.indent .. indentchar or "",
	}
	if params then
		for k,v in ipairs(params) do
			x.params[v] = true
			x.locals[v] = true
		end
	end
	local maxtemp = 0
	if body.type then
		maxtemp = singlestatement(body, s, x, maxtemp)
	else
		for k,v in ipairs(body) do
			x.temp = 0
			maxtemp = singlestatement(v, s, x, maxtemp)
		end
	end
	local o = ctx.out
	local l = list()
	if ctx.indent then
		l '\n'
		l(x.indent)
	else
		ctx.indent = ""
	end
	l 'local '
	local b = false
	local locals = list()
	for k,v in pairs(x.locals) do
		locals(k)
	end
	local p = 2
	while locals[p] do
		local a, b = locals[p-1], locals[p]
		if a > b then
			locals[p-1], locals[p] = b, a
			if p > 2 then p = p - 1 end
		else p = p + 1 end
	end
	for _,k in ipairs(locals) do
		ctx.shared.idents[k] = true
		if not x.params[k] then
			if b then l ', ' else b = true end
			l(k)
		end
	end
	for i = 0, maxtemp-1 do
		if b then l ', ' else b = true end
		l(i)
	end
	if b then
		o(l)
	end
	for k,v in pairs(x.globals) do ctx.shared.idents[k] = true end
	o(s)
end

function node(t, ctx)
	local ty = t.type
	-- print("node: " .. ty)
	if ty == "file" then
		functionbody(t.value, ctx, nil, true)
	elseif ty == "assignmentstatement" then
		local s = list()
		local b = false
		for k,v in ipairs(t.vars) do
			if b then s ', ' else b = true end
			if v.type == "identifier" then
				if not vartype(ctx, v.value) then
					ctx.locals[v.value] = true
				end
			end
			s(node(v, ctx))
		end
		s ' = '
		b = false
		for k,v in ipairs(t.vals) do
			if b then s ', ' else b = true end
			s(node(v, ctx))
		end
		return s
	elseif ty == "identifier" then
		local b, c = vartype(ctx, t.value)
		if b and c == "global" then
			return "_ENV." .. t.value
		end
		return t.value
	elseif ty == "postincrement" or ty == "postdecrement" then
		local inc = ty == "postincrement"
		if t.isstatement then -- statement-mode
			inc = inc and ' + 1' or ' - 1'
			if t.value.type == "identifier" then
				ctx.out(t.value.value) ' = ' (t.value.value)
				return inc
			elseif t.value.type == "tableindex" then
				local o = ctx.out
				local tbl, key = t.value.table, t.value.key
				if not islid(tbl) then
					tbl = node(tbl, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (tbl) '\n' (ctx.indent)
					tbl = temp
				else tbl = node(tbl, ctx) end
				local identkey = key.type == "identifier"
				if not islid(key) then
					key = node(key, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (key) '\n' (ctx.indent)
					key = temp
				else key = node(key, ctx) end
				if identkey then
					o(tbl) '.' (key) ' = ' (tbl) '.' (key)
				else
					o(tbl) '[' (key) '] = ' (tbl) '[' (key) ']'
				end
				return inc
			else complain(ctx, t.token, "attempt to perform a %s on a %s-node", t.type, t.value.type) end
		else -- expression-mode
			inc = inc and ' + 1\n' or ' - 1\n'
			if t.value.type == "identifier" then
				local v = t.value.value
				local temp = ctx.temp
				ctx.temp = temp + 1
				ctx.out(temp) ' = ' (v) '\n' (ctx.indent) (v) ' = ' (temp) (inc) (ctx.indent)
				return temp
			elseif t.value.type == "tableindex" then
				local o = ctx.out
				local tbl, key = t.value.table, t.value.key
				if not islid(tbl) then
					tbl = node(tbl, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (tbl) '\n' (ctx.indent)
					tbl = temp
				else tbl = node(tbl, ctx) end
				local identkey = key.type == "identifier"
				if not islid(key) then
					key = node(key, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (key) '\n' (ctx.indent)
					key = temp
				else key = node(key, ctx) end
				local temp = ctx.temp
				ctx.temp = temp + 1
				if identkey then
					o(temp) ' = ' (tbl) '.' (key) '\n' (ctx.indent)
					o(tbl) '.' (key) ' = ' (temp) (inc) (ctx.indent)
				else
					o(temp) ' = ' (tbl) '[' (key) ']\n' (ctx.indent)
					o(tbl) '[' (key) '] = ' (temp) (inc) (ctx.indent)
				end
				return temp
			else complain(ctx, t.token, "attempt to perform a %s on a %s-node", t.type, t.value.type) end
		end
	elseif ty == "preincrement" or ty == "predecrement" then
		local inc = ty == "preincrement"
		if t.isstatement then -- statement-mode
			inc = inc and ' + 1' or ' - 1'
			if t.value.type == "identifier" then
				ctx.out(t.value.value) ' = ' (t.value.value)
				return inc
			elseif t.value.type == "tableindex" then
				local o = ctx.out
				local tbl, key = t.value.table, t.value.key
				if not islid(tbl) then
					tbl = node(tbl, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (tbl) '\n' (ctx.indent)
					tbl = temp
				else tbl = node(tbl, ctx) end
				local identkey = key.type == "identifier"
				if not islid(key) then
					key = node(key, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (key) '\n' (ctx.indent)
					key = temp
				else key = node(key, ctx) end
				if identkey then
					o(tbl) '.' (key) ' = ' (tbl) '.' (key)
				else
					o(tbl) '[' (key) '] = ' (tbl) '[' (key) ']'
				end
				return inc
			else complain(ctx, t.token, "attempt to perform a %s on a %s-node", t.type, t.value.type) end
		else -- expression-mode
			inc = inc and ' + 1\n' or ' - 1\n'
			if t.value.type == "identifier" then
				local v = t.value.value
				ctx.out(v) ' = ' (v) (inc) (ctx.indent)
				return v
			elseif t.value.type == "tableindex" then
				local o = ctx.out
				local tbl, key = t.value.table, t.value.key
				if not islid(tbl) then
					tbl = node(tbl, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (tbl) '\n' (ctx.indent)
					tbl = temp
				else tbl = node(tbl, ctx) end
				local identkey = isstringandvalidident(key)
				if identkey then
					key = key.value
				elseif not islid(key) then
					key = node(key, ctx)
					local temp = ctx.temp
					ctx.temp = temp + 1
					o(temp) ' = ' (key) '\n' (ctx.indent)
					key = temp
				else key = node(key, ctx) end
				local temp = ctx.temp
				ctx.temp = temp + 1
				if identkey then
					o(temp) ' = ' (tbl) '.' (key) (inc) (ctx.indent)
					o(tbl) '.' (key) ' = ' (temp) '\n' (ctx.indent)
				else
					o(temp) ' = ' (tbl) '[' (key) ']' (inc) (ctx.indent)
					o(tbl) '[' (key) '] = ' (temp) '\n' (ctx.indent)
				end
				return temp
			else complain(ctx, t.token, "attempt to perform a %s on a %s-node", t.type, t.value.type) end
		end
	elseif ty == "tableliteral" then
		if t.keys.n == 0 then return '{}' end
		local s = list()
		s '{'
		local oi = ctx.indent
		ctx.indent = oi .. indentchar
		local b = false
		local nextkey = 1
		for k,v in ipairs(t.keys) do
			if b then s ',' else b = true end
			s '\n' (ctx.indent)
			if v.type == "number" and v.value == nextkey then
				nextkey = nextkey + 1
			elseif v.type == "identifier" then
				s(v.value) ' = '
			else
				s '[' (node(v, ctx)) '] = '
			end
			s(node(t.values[k], ctx))
		end
		ctx.indent = oi
		s '\n' (ctx.indent) '}'
		return s
	elseif ty == "tableindex" then
		local s = list()
		local tt = t.table.type
		if tt == "identifier" or tt == "tableindex" or tt == "call" then
			s(node(t.table, ctx))
		else
			s '(' (node(t.table, ctx)) ')'
		end
		-- if t.key.type == "identifier" then
		if isstringandvalidident(t.key) then
			s '.' (t.key.value)
		else
			s '[' (node(t.key, ctx)) ']'
		end
		return s
	elseif ty == "functionstatement" then
		if t.name then -- statement-mode
			local o = ctx.out
			o 'function '
			local method = false
			if t.tablename then
				o(t.tablename)
				if t.params[1] == "self" then
					method = true
					o ':'
				else
					o '.'
				end
			else
				local b,c = vartype(ctx, t.name)
				if t.glob then
					if b and c ~= "global" then
						complain(ctx, t.token, "attempt to make global function with local variable '%s'", t.name)
					end
					ctx.globals[t.name] = true
					b,c = vartype(ctx, t.name)
				end
				if not b then
					ctx.locals[t.name] = true
				elseif c == "global" then
					o '_ENV.'
				end
			end
			o(t.name)
			o '('
			local b = false
			for k,v in ipairs(t.params), t.params, (method and 1 or 0) do
				if b then o ', ' else b = true end
				o(v)
			end
			if t.vararg then
				if b then
					o ', '
				end
				o '...'
			end
			o ')'
			functionbody(t.body, ctx, t.params, t.vararg)
			o '\n'
			o(ctx.indent)
			return 'end\n'
		else -- expression-mode
			local s = list()
			s 'function('
			local b = false
			for k,v in ipairs(t.params) do
				if b then s ', ' else b = true end
				s(v)
			end
			if t.vararg then
				if b then
					s ', '
				end
				s '...'
			end
			s ')'
			local o = ctx.out
			ctx.out = s
			functionbody(t.body, ctx, t.params, t.vararg)
			ctx.out = o
			s '\n'
			s(ctx.indent)
			s 'end'
			return s
		end
	elseif ty == "return" then
		local s = list()
		s 'return '
		local b = false
		for k,v in ipairs(t.value) do
			if b then s ', ' else b = true end
			s(node(v, ctx))
		end
		return s
	elseif ty == "gotostatement" then
		return list() 'goto ' (t.value)
	elseif ty == "label" then
		return list() '::' (t.value) '::'
	elseif ty == "globalstatement" then
		for k,v in ipairs(t.vars) do
			if ctx.locals[v] then
				complain(ctx, t.token, "variable %s is already local, and can't be made global", v)
			else
				ctx.globals[v] = true
			end
		end
		return ''
	elseif ty == "varstatement" then
		for k,v in ipairs(t.vars) do
			if ctx.globals[v] then
				complain(ctx, t.token, "variable %s is already global, and can't be made local", v)
			else
				ctx.locals[v] = true
			end
		end
		return ''
	elseif ty == "call" then
		local s = list()
		if t.table then -- method
			local tt = t.table.type
			if tt == "identifier" or tt == "call" or tt == "tableindex" then
				s(node(t.table, ctx))
			else
				s '(' (node(t.table, ctx)) ')'
			end
			s ':' (t.key)
		else -- regular function
			local ft = t.func.type
			if ft == "identifier" or ft == "tableindex" or ft == "call" then
				s(node(t.func, ctx))
			else
				s '('
				s(node(t.func, ctx))
				s ')'
			end
		end
		if t.args.n == 1 and t.args[1].type == "string" then
			s ' '
			s(node(t.args[1], ctx))
		else
			s '('
			local b = false
			for k,v in ipairs(t.args) do
				if b then s ', ' else b = true end
				s(node(v, ctx))
			end
			s ')'
		end
		return s
	elseif ty == "statements" then
		local b = false
		for k,v in ipairs(t.body) do
			if b then
				ctx.out '\n'
				ctx.out(ctx.indent)
			else b = true end
			ctx.temp = 0
			ctx.out(node(v, ctx))
		end
		return ''
	elseif ty == "binop" then
		local op = onetoonebinops[t.op]
		if op then
			local rightassociative = t.op == "pow" or t.op == "concat"
			local s = list()
			if lesserprecedence(t.left, t, rightassociative) then
				s '('
				s(node(t.left, ctx))
				s ')'
			else
				s(node(t.left, ctx))
			end
			s ' '
			s(op.symbol)
			s ' '
			if not (t.op == "pow" and t.right.op == "unary") and lesserprecedence(t.right, t, not rightassociative) then
				s '('
				s(node(t.right, ctx))
				s ')'
			else
				s(node(t.right, ctx))
			end
			return s
		end
		op = bitops[t.op]
		if op then
			-- ugh, it's a bitop
			local can = usebitop(ctx, t.op)
			if not can then
				complain(ctx, t.token, "attempted to use a bitop (%s) while bitops are not present:", t.op)
				return ''
			end
			if bit53 then
				local s = list()
				if lesserprecedence(t.left, t) then
					s '('
					s(node(t.left, ctx))
					s ')'
				else
					s(node(t.left, ctx))
				end
				s ' '
				s(op.symbol)
				s ' '
				if lesserprecedence(t.right, t, true) then
					s '('
					s(node(t.right, ctx))
					s ')'
				else
					s(node(t.right, ctx))
				end
				return s
			end
			-- todo: flatten bitops when operators aren't present
			local s = list()
			s(node({
				type = "identifier",
				value = t.op,
				token = t.token,
			}, ctx)) '(' (node(t.left, ctx)) ', ' (node(t.right, ctx)) ')'
			return s
		end
		error(("binop not 1:1 (%s)"):format(t.op))
	elseif ty == "if" then
		local s = list()
		s 'if '
		s(node(t.cond, ctx))
		s ' then\n'
		local bi = ctx.indent
		local oi = bi
		local ni = oi .. indentchar
		ctx.indent = ni
		s(ctx.indent)
		local o = ctx.out
		o(s)
		o(node(t.body, ctx))
		local indents = list()(bi)
		for k,v in ipairs(t.elseifs) do
			o '\n'
			ctx.indent = oi
			o(ctx.indent)
			o 'else\n'
			oi, ni = ni, ni .. indentchar
			indents(oi)
			ctx.indent = oi
			o(ctx.indent)
			local s = list()
			s 'if '
			s(node(v.cond, ctx))
			s ' then\n'
			ctx.indent = ni
			s(ctx.indent)
			o(s)
			o(node(v.body, ctx))
		end
		if t.elsebody then
			o '\n'
			ctx.indent = oi
			o(ctx.indent)
			o 'else\n'
			ctx.indent = ni
			o(ctx.indent)
			o(node(t.elsebody, ctx))
		end
		for i = indents.n, 1, -1 do
			local v = indents[i]
			o '\n'
			o(v)
			o 'end'
		end
		ctx.indent = bi
		return ""
	elseif ty == "compare" then
		local s = list()
		local v = t.value
		local left = node(v[1], ctx)
		for i = 2, v.n-1, 2 do
			local last = not v[i+2]
			local right = v[i+1]
			if not last and right.type ~= "identifier" then
				right = node(right, ctx)
				local o = ctx.out
				local temp = Temp(ctx)
				o(temp) ' = ' (right) '\n' (ctx.indent)
				right = temp
			else
				right = node(right, ctx)
			end
			local op = v[i]
			s(left) ' ' (compareops[op].symbol) ' ' (right)
			left = right
			if not last then
				s ' and '
			end
		end
		return s
	elseif ty == "rangeloop" then
		local s = list()
		s 'for '
		local var = t.var
		local lvar = ctx.locals[var]
		local gvar = ctx.globals[var]
		ctx.locals[var] = true
		ctx.globals[var] = false
		s(var)
		s ' = '
		s(t.start and node(t.start, ctx) or "1")
		s ', '
		s(node(t.stop, ctx))
		if t.step then
			s ', '
			s(node(t.step, ctx))
		end
		s ' do\n'
		local oi = ctx.indent
		ctx.indent = oi .. indentchar
		s(ctx.indent)
		local o = ctx.out
		o(s)
		o(node(t.body, ctx))
		o '\n'
		ctx.indent = oi
		o(ctx.indent)
		ctx.locals[var] = lvar
		ctx.globals[var] = gvar
		return 'end'
	elseif ty == "while" then
		local s = list()
		s 'while '
		s(node(t.cond, ctx))
		s ' do\n'
		local oi = ctx.indent
		ctx.indent = oi .. indentchar
		s(ctx.indent)
		local o = ctx.out
		o(s)
		o(node(t.body, ctx))
		o '\n'
		ctx.indent = oi
		o(ctx.indent)
		return 'end'
	elseif ty == "import" then
		local o = ctx.out
		local b,c = vartype(ctx, t.to)
		if not b then
			ctx.locals[t.to] = true
		elseif c == "global" then
			o '_ENV.'
		end
		o(t.to)
		o ' = require '
		if t.from.type == "string" then
			return node(t.from, ctx)
		end
		o '"' (t.from.value)
		return '"'
	elseif ty == "use" then
		local o = ctx.out
		local temp
		if not t.import and t.from.type == "identifier" then
			temp = t.from.value
		else
			temp = ctx.temp
			ctx.temp = temp + 1
			if t.import then
				o(temp)
				o ' = require "'
				o(t.from.value)
				o '"'
			else
				local v = node(t.from, ctx)
				o(temp)
				o ' = '
				o(v)
			end
		end
		for k,v in ipairs(t.aliases) do
			local o = ctx.out
			o '\n' (ctx.indent)
			local b,c = vartype(ctx, v)
			if not b then
				ctx.locals[v] = true
			elseif c == "global" then
				o '_ENV.'
			end
			o(v)
			o ' = '
			o(temp)
			o '.'
			o(t.names[k])
		end
		return ""
	elseif ty == "genericloop" then
		local s = list()
		s 'for '
		local b = false
		for k,v in ipairs(t.vars) do
			if b then s ', ' else b = true end
			s(v)
		end
		s ' in '
		b = false
		for k,v in ipairs(t.vals) do
			if b then s ', ' else b = true end
			s(node(v, ctx))
		end
		s ' do\n'
		local oi = ctx.indent
		ctx.indent = oi .. indentchar
		s(ctx.indent)
		local o = ctx.out
		o(s)
		o(node(t.body, ctx))
		ctx.indent = oi
		o '\n'
		o(ctx.indent)
		return "end"
	elseif ty == "compoundassignmentstatement" then
		local s = list()
		local var = t.var
		if var.type == "identifier" then
			var = node(var, ctx)
		elseif var.type == "tableindex" then
			local tbl, key = var.table, var.key
			local ident = tbl.type == "identifier"
			tbl = node(tbl, ctx)
			if not ident then
				local temp = ctx.temp
				ctx.temp = temp + 1
				s(temp) ' = ' (tbl) '\n' (ctx.indent)
				tbl = temp
			end
			local ident = isstringandvalidident(key)
			if ident then
				key = key.value
			elseif islid(key) then
				key = node(key, ctx)
			else
				local temp = ctx.temp
				ctx.temp = temp + 1
				s(temp) ' = ' (node(key, ctx)) '\n' (ctx.indent)
				key = temp
			end
			var = list()
			if ident then
				var(tbl) '.' (key)
			else
				var(tbl) '[' (key) ']'
			end
		else complain(ctx, t.token, "compound assignment with invalid lvalue '%s'", t.type, t.var.type) end
		local op = assert(onetoonebinops[t.op], t.op)
		s(var) ' = ' (var) ' ' (op.symbol)
		if t.val.type == "binop" and op.precedence > assert(onetoonebinops[t.val.op], t.val.op).precedence then
			s ' (' (node(t.val, ctx)) ')'
		else
			s ' ' (node(t.val, ctx))
		end
		return s
	elseif ty == "compoundassign" then
		local s = list()
		local o = ctx.out
		local var = t.left
		if var.type == "identifier" then
			var = node(var, ctx)
		elseif var.type == "tableindex" then
			local s = list()
			if var.table.type == "identifier" then
				s(node(var.table, ctx))
			else
				local temp = Temp(ctx)
				o(temp) ' = ' (node(var.table, ctx)) '\n' (ctx.indent)
				s(temp)
			end
			if isstringandvalidident(var.key) then
				s '.' (var.key.value)
			else
				local temp = Temp(ctx)
				o(temp) ' = ' (node(var.key, ctx)) '\n' (ctx.indent)
				s '[' (temp) ']'
			end
			var = s
		else complain(ctx, t.token, "compound assignment with invalid lvalue '%s'", t.type, t.var.type) end
		if t.isstatement then
			complain(ctx, t.token, "<%s>.isstatement == true, but case is not implemented", t.type)
		else
			local temp = Temp(ctx)
			local op = assert(onetoonebinops[t.op], t.op)
			o(temp) ' = ' (var) ' ' (op.symbol) ' ' (node(t.right, ctx)) '\n' (ctx.indent)
			o(var) ' = ' (temp) '\n' (ctx.indent)
			return temp
		end
	elseif ty == "repeatuntil" then
		local o = ctx.out
		o 'repeat\n'
		local oi = ctx.indent
		ctx.indent = oi .. indentchar
		o(ctx.indent)
		o(node(t.body, ctx))
		ctx.indent = oi
		o '\n'
		o(ctx.indent)
		local n = node(t.cond, ctx)
		o 'until '
		o(n)
		return ''
	elseif ty == "assign" then
		local o = ctx.out
		local notemp = false
		if t.left.type == "identifier" then
			local value = t.left.value
			local b,e = vartype(ctx, value)
			if not b then
				ctx.locals[value] = true
				notemp = true
			elseif e == "local" then
				notemp = true
			end
		end
		local left = node(t.left, ctx)
		local right = node(t.right, ctx)
		if notemp then
			o (left) ' = ' (right) '\n' (ctx.indent)
			return left
		else
			local temp = Temp(ctx)
			o (temp) ' = ' (right) '\n' (ctx.indent) (left) ' = ' (temp) '\n' (ctx.indent)
			return temp
		end
	elseif ty == "vararg" then
		if not ctx.vararg then
			complain(ctx, t.token, "cannot use '...' outside of vararg function")
		end
		return '...'
	elseif ty == "not" or ty == "negate" or ty == "len" then
		local s = assert(unaryops[ty], ty).symbol
		local n = node(t.value, ctx)
		if lesserprecedence(t.value, t) then
			return list()(s) '(' (n) ')'
		end
		return list()(s)(n)
	elseif ty == "nil" then
		return 'nil'
	elseif ty == "number" then
		return list()(tostring(t.value))
	elseif ty == "string" then
		return ("%q"):format(t.value):gsub('\n','n')
	elseif ty == "bool" then
		return t.value and "true" or "false"
	elseif ty == "break" then
		return "break"
	elseif ty == "nop" then return ''
	else
		complain(ctx, t.token, "unknown node type %q", t.type)
		return ''
	end
end

local function resolvebitops(ctx)
	local u = ctx.shared.usedbitops
	if next(u, nil) == nil then return end
	local s = list()
	s 'local '
	local b = false
	for k,v in pairs(u) do
		if b then s ', ' else b = true end
		s(k)
	end
	s '\ndo local bitlib = '
	if jitbit then
		s 'require "bit"'
	else
		s 'bit32'
	end
	s '\n'
	b = false
	local values = list()
	for k,v in pairs(u) do
		if b then s ', ' values ', ' else b = true end
		s(k)
		values 'bitlib.' (k)
	end
	s ' = ' (values) ' end\n'
	return s
end

local function flatten(t, s)
	if not t.n then
		for k,v in pairs(t) do
			print(k,v)
		end
	end
	for i = 1, t.n do
		local v = t[i]
		if type(v) == "table" then
			flatten(v, s)
		else
			s(v)
		end
	end
	return s
end

local function tempvarname(ctx, index)
	local s = ctx.shared
	local i, t = s.idents, s.tempvars
	local n = t[index]
	if n then
		return n
	end
	repeat
		n = s.nexttempvar
		s.nexttempvar = n + 1
		n = tempname(n)
		-- print(n, i[n])
	until not i[n]
	t[index] = n
	return n
end

return function(t)
	if t.type ~= "file" then
		return nil, "top-most node is not a 'file' node"
	end
	
	local out = list()
	local ctx = {
		out = out,
		locals = {},
		globals = {},
		params = {},
		upctx = false,
		vararg = true,
		temp = 0,
		shared = {
			idents = {},
			tempvars = {},
			nexttempvar = 0,
			errors = list(),
			usedbitops = {},
		},
	}
	
	node(t, ctx)
	local bitstuff = resolvebitops(ctx)
	local s = list()
	if bitstuff then flatten(bitstuff, s) end
	flatten(out, s)
	for k = 1, s.n do
		local v = s[k]
		if type(v) == "number" then
			s[k] = tempvarname(ctx, v)
		elseif type(v) ~= "string" then
			s[k] = "$" .. tostring(v)
		end
	end
	local lua = table.concat(s)
	local e = ctx.shared.errors
	if e.n ~= 0 then
		return nil, table.concat(e, '\n\n'), lua
	end
	return lua
end

