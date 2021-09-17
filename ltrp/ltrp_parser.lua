local list = require((...):match("^(.-)[^%./\\]*$") .. "ltrp_list")

local ast = {}
ast.__index = ast

local function new(tokens)
	return setmetatable({
		tokens = tokens,
		stack = list(),
		p = 1,
		errors = list(),
	}, ast)
end

local function islvalue(t) return t.type == "identifier" or t.type == "tableindex" end

function ast:__call(cmd, arg)
	if cmd == true then
		return self.tokens[self.p]
	elseif not cmd then
		local p = self.p
		local tokens = self.tokens
		while tokens[p].whitespace do p = p + 1 end
		return tokens[p]
	elseif cmd == "push" then
		self.stack(self.p)
		return self(nil)
	elseif cmd == "pop" then
		local n = self.stack.n
		self.stack.n = n - 1
	elseif cmd == "pull" then
		local n = self.stack.n
		self.p = self.stack[n]
		self.stack.n = n - 1
		return false
	else
		local p = self.p
		local tokens = self.tokens
		while true do
			local t = tokens[p] or tokens[tokens.n]
			if t.type == cmd and (arg == nil or arg == t.value) then
				self.p = p + 1
				return t.value or true
			elseif t.whitespace then
				p = p + 1
			else
				return false
			end
		end
	end
end

local function complain(self, str, token)
	self.errors(token:makecomplaint(str))
end

function ast:expect(cmd, err, arg)
	local x = self(cmd, arg)
	if not x then
		complain(self, (err or cmd) .. " expected near:", self(nil))
	end
	return x
end

function ast:anticipate(func, err, ...)
	local x, y = assert(self[func], func)(self, ...)
	if not x then
		complain(self, (err or func) .. " expected near:", self(nil))
	end
	return x, y
end

function ast:file()
	local rel = self "push"
	local l = list()
	while not self "eof" do
		local s = self:anticipate("statement", "statement")
		l(s)
		if not s then
			self(self().type)
		end
	end
	self "pop"
	local res = {
		type = "file",
		value = l,
		token = rel,
	}
	if self.errors.n ~= 0 then
		local n = self.errors.n
		self.errors(("%i errors"):format(n))
		return nil, table.concat(self.errors, '\n'), res
	end
	return res
end

local compoundoperators = {
	add = true,
	sub = true,
	mul = true,
	div = true,
	mod = true,
	pow = true,
	['or'] = true,
	['and'] = true,
}

function ast:compoundassignmentstatement()
	local rel = self "push"
	local lval = self:lvalue()
	if not lval then
		return self "pull"
	end
	local op = self()
	if not compoundoperators[op.type] then
		return self "pull"
	end
	self(op.type)
	if not self "assign" then
		return self "pull"
	end
	local expr = self:anticipate "expression"
	self "pop"
	return {
		type = "compoundassignmentstatement",
		op = op.type,
		var = lval,
		val = expr,
		token = op,
	}
end

function ast:statement()
	local rel = self "push"
	local s = self:statements()
		or self:keywordstatement()
		or self:compoundassignmentstatement()
		or self:assignstatement()
		or self:callstatement()
		or self:postopstatement()
	if s then
		self "semicolon"
		self "pop"
		return s
	elseif self "semicolon" then
		self "pop"
		return {
			type = "nop",
			token = rel,
		}
	end
	return self "pull"
end

function ast:postopstatement()
	local rel = self "push"
	local expr = self:post_only_expression()
	if expr and (expr.type == "postincrement" or expr.type == "postdecrement") then
		expr.isstatement = true
		self "pop"
		return expr
	end
	return self "pull"
end

function ast:keywordstatement()
	return self:functionstatement()
		or self:returnstatement()
		or self:globalstatement()
		or self:ifstatement()
		or self:forstatement()
		or self:whilestatement()
		or self:breakstatement()
		or self:importstatement()
		or self:repeatuntilstatement()
		or self:varstatement()
		or self:gotostatement()
		or self:labelstatement()
end

function ast:gotostatement()
	local rel = self "push"
	if not self "goto" then return self "pull" end
	local label = self:expect "ident"
	self "pop"
	return {
		type = "gotostatement",
		value = label,
		token = rel,
	}
end

function ast:labelstatement()
	local rel = self "push"
	if not self "labelpart" then return self "pull" end
	rel = self()
	local name = self:expect "ident"
	self:expect "labelpart"
	self "pop"
	return {
		type = "label",
		value = name,
		token = rel,
	}
end

function ast:varstatement()
	local rel = self "push"
	if not self("ident", "var") then return self "pull" end
	local vars = list()
	repeat
		vars(self:expect "ident")
	until not self "comma"
	self "pop"
	return {
		type = "varstatement",
		vars = vars,
		token = rel,
	}
end

function ast:repeatuntilstatement()
	local rel = self "push"
	if self "repeat" then
		local body = self:anticipate "statement"
		self:expect "until"
		local cond = self:anticipate "expression"
		self "pop"
		return {
			type = "repeatuntil",
			body = body,
			cond = cond,
			token = rel,
		}
	end
	return self "pull"
end

function ast:importstatement()
	local rel = self "push"
	if self "import" then
		local alias
		local name = self:stringliteral()
		if name then
			alias = name.value:match "([%a_][%w_]*).-$"
			if (alias and self("ident", "as")) or (not alias and self:expect("ident", "'as'", "as")) then
				alias = self:expect "ident"
			end
		else
			name = self:anticipate("ident", "import name")
			alias = name and name.value
			if self("ident", "as") then
				alias = self:expect("ident", "import alias")
			end
		end
		self "pop"
		return {
			type = "import",
			from = name,
			to = alias,
			token = rel,
		}
	elseif self("ident", "from") then
		local name = self:expression()
		local import = (name.type == "ident" or name.type == "string") and self "import"
		if import or self:expect("use", "import or use") then
			local names = list()
			local aliases = list()
			repeat
				local name = self:expect "ident"
				local alias = name
				if self("ident", "as") then
					alias = self:expect "ident"
				end
				names(name)
				aliases(alias)
			until not self "comma"
			self "pop"
			return {
				type = "use",
				from = name,
				names = names,
				aliases = aliases,
				import = import or false,
			}
		end
	end
	return self "pull"
end

function ast:breakstatement()
	local rel = self()
	if self("ident", "break") then
		return {
			type = "break",
			token = rel,
		}
	end
end

function ast:whilestatement()
	local rel = self "push"
	if self "while" then
		local cond = self:anticipate "expression"
		if not self "newline" then self "colon" end
		local body = self:anticipate "statement"
		self "pop"
		return {
			type = "while",
			cond = cond,
			body = body,
			token = rel,
		}
	end
	return self "pull"
end

function ast:forstatement()
	local rel = self "push"
	if self "for" then
		local var = self:expect("ident", "iterator variable")
		if self "assign" then -- range-loop
			local start, step
			local stop
			stop = self:anticipate "expression"
			if self "comma" then
				start = stop
				stop = self:anticipate "expression"
				if self "comma" then
					step = self:anticipate "expression"
				end
			end
			if not self "newline" then self "colon" end
			local body = self:anticipate "statement"
			self "pop"
			return {
				type = "rangeloop",
				var = var,
				start = start or false,
				stop = stop or false,
				step = step or false,
				body = body,
				token = rel,
			}
		else -- generic-loop
			local vars = list()(var)
			while self "comma" do
				vars(self:expect "ident")
			end
			self:expect("ident", "in", "in")
			local vals = self:anticipate "comma_separated_expressions"
			if not self "newline" then self "colon" end
			local body = self:anticipate "statement"
			self "pop"
			return {
				type = "genericloop",
				vars = vars,
				vals = vals,
				body = body,
				token = rel,
			}
		end
	end
	return self "pull"
end

function ast:ifstatement()
	local rel = self "push"
	if self "if" then
		local cond = self:anticipate("expression", "if condition")
		if not self "newline" then self "colon" end
		local body = self:anticipate("statement", "if body")
		local elsebody = false
		local elseifs = list()
		while self "elseif" do
			local cond = self:anticipate("expression", "elseif condition")
			if not self "newline" then self "colon" end
			local body = self:anticipate("statement", "elseif body")
			elseifs {
				cond = cond,
				body = body,
			}
		end
		if self "else" then
			if not self "newline" then self "colon" end
			elsebody = self:anticipate("statement", "else body")
		end
		self "pop"
		return {
			type = "if",
			cond = cond,
			body = body,
			elseifs = elseifs,
			elsebody = elsebody,
			token = rel,
		}
	end
	return self "pull"
end

function ast:call(t)
	local rel = self "push"
	if self "newline" then
		return self "pull"
	end
	local args = nil
	if self(true).type == "exclamation" then
		self "exclamation"
		args = list()
	elseif self "lparen" then
		args = list()
		if not self "rparen" then
			repeat
				args(self:anticipate("expression", "argument"))
			until not self "comma"
			self:expect("rparen")
		end
	else
		local space = self(true)
		local arg = self:expression()
		if not arg then return self "pull" end
		do -- negation- and inversion-check
			local a = arg
			while a.type == "binop" do
				a = a.left
			end
			if a.token.type == "sub" or (a.token.type == "exclamation" and space.type ~= "space") then
				return self "pull"
			end
		end
		args = list()(arg)
		while self "comma" do
			args(self:anticipate("expression", "argument"))
		end
	end
	if args then
		self "pop"
		return {
			type = "call",
			func = t,
			args = args,
			token = rel,
		}
	end
	return self "pull"
end

function ast:callstatement()
	local rel = self "push"
	local e = self:post_only_expression()
	if e and e.type == "call" then
		self "pop"
		return e
	end
	
	return self "pull"
end

function ast:globalstatement()
	local rel = self "push"
	if self("ident", "glob") then
		local l = list()
		repeat
			local name = self:expect("ident", "global variable name")
			if name then l(name) end
		until not self "comma"
		self "pop"
		return {
			type = "globalstatement",
			vars = l,
			token = rel,
		}
	end
	return self "pull"
end

function ast:assignstatement()
	local rel = self "push"
	local vars = list()
	local var = self:lvalue()
	if not var then
		return self "pull"
	end
	vars(var)
	while self "comma" do
		vars(self:anticipate("lvalue"))
	end
	if vars.n == 1 then
		if not self "assign" then
			return self "pull"
		end
	else
		self:expect "assign"
	end
	local vals = list()
	repeat
		vals(self:anticipate("expression"))
	until not self "comma"
	self "pop"
	return {
		type = "assignmentstatement",
		vars = vars,
		vals = vals,
		token = rel,
	}
end

function ast:lvalue()
	local rel = self "push"
	local e = self:post_only_expression()
	if e and islvalue(e) then
		self "pop"
		return e
	end
	return self "pull"
end

function ast:bottomexpression()
	return self:ident()
		or self:literal()
		or self:vararg()
		or self:functionstatement(true)
end

function ast:vararg()
	local rel = self()
	return self "vararg" and {
		type = "vararg",
		token = rel,
	}
end

function ast:ident()
	local rel = self "push"
	local s = self "ident"
	if s then
		self "pop"
		return {
			type = "identifier",
			value = s,
			token = rel
		}
	end
	return self "pull"
end

function ast:returnstatement()
	local rel = self "push"
	if self "ret" then
		local exprs = self:comma_separated_expressions()
		self "pop"
		return {
			type = "return",
			value = exprs or list(),
			token = rel,
		}
	end
	return self "pull"
end

function ast:pre_expr_unop()
	local rel = self "push"
	local op = self "sub" and "negate"
		or self "not" and "not"
		or self "exclamation" and "not"
		or self "bnot" and "bnot"
		or self "len" and "len"
	local lval = false
	if not op then
		op = (self "increment" and "preincrement")
			or (self "decrement" and "predecrement")
		if op then
			lval = true
		end
	end
	if op and not self "newline" then
		local expr = self:pre_expression()
		if expr and not (lval and not islvalue(expr)) then
			self "pop"
			return {
				type = op,
				value = expr,
				token = rel,
				op = "unary",
			}
		end
	end
	return self "pull"
end

function ast:pre_expression()
	return self:pre_expr_unop()
		or self:post_only_expression()
end

function ast:paren_expression()
	local rel = self "push"
	if self "lparen" then
		local expr = self:anticipate("expression")
		self:expect "rparen"
		self "pop"
		return expr
	end
	return self "pull"
end

function ast:key()
	return self:ident()
		or self:literal()
end

function ast:index(t)
	local rel = self "push"
	local key = false
	if self "dot" then
		key = self:anticipate("key", "key")
		if key.type == "identifier" then
			key = {
				type = "string",
				value = key.value,
				token = key.token,
			}
		end
	elseif self "lsquare" then
		key = self:anticipate("expression", "index")
		self:expect("rsquare", "closing square bracket")
	else
		return self "pull"
	end
	local expr = {
		type = "tableindex",
		table = t,
		key = key,
		token = rel,
	}
	self "pop"
	return expr
end

function ast:post_op(t)
	local rel = self "push"
	local op = (self "increment" and "postincrement") or (self "decrement" and "postdecrement")
	if op then
		self "pop"
		return {
			type = op,
			value = t,
			token = rel,
		}
	end
	return self "pull"
end

function ast:post_only_expression()
	local rel = self "push"
	local expr = self:bottomexpression() or self:paren_expression()
	if expr then
		while true do
			local post = self:post_expression(expr)
			if not post then break end
			expr = post
		end
		self "pop"
		return expr
	end
	return self "pull"
end

function ast:post_expression(t)
	return self:index(t)
		or self:pow(t)
		or self:methodcall(t)
		or self:call(t)
		or (islvalue(t) and self:post_op(t))
end

function ast:implicitselfcall(t)
	local rel = self "push"
end

function ast:pow(left)
	local rel = self "push"
	if self "pow" then
		local right = self:anticipate "pre_expression"
		self "pop"
		return {
			type = "binop",
			op = "pow",
			left = left,
			right = right,
			token = rel,
		}
	end
	return self "pull"
end

function ast:parenargs()
	local rel = self "push"
	if not self "lparen" then
		return self "pull"
	end
	local args = list()
	if not self "rparen" then
		repeat
			args(self:anticipate 'expression')
		until not self "comma"
		self:expect 'rparen'
	end
	self "pop"
	return args
end

function ast:methodcall(t)
	local rel = self "push"
	if not self "colon" then
		return self "pull"
	end
	do
		local space = self(true)
		if t.type == "identifier" and space.type == "exclamation" then
			self "exclamation"
			self "pop"
			return {
				type = "call",
				table = {
					type = "identifier",
					value = "self",
					token = t.token,
				},
				key = t.value,
				args = list(),
				token = rel,
			}
		elseif t.type == "identifier" and space.type == "lparen" then
			local args = self:anticipate 'parenargs'
			self "pop"
			return {
				type = "call",
				table = {
					type = "identifier",
					value = "self",
					token = t.token,
				},
				key = t.value,
				args = args,
				token = rel,
			}
		elseif space.type ~= "ident" then
			return self "pull"
		end
	end
	local name = self:expect "ident"
	local args
	if self(true).type == "exclamation" then
		self "exclamation"
		args = list()
	elseif self "lparen" then
		args = list()
		if not self "rparen" then
			repeat
				args(self:anticipate("expression", "argument"))
			until not self "comma"
			self:expect "rparen"
		end
	else
		local arg = self:expression()
		if arg then
			args = list()(arg)
			while self "comma" do
				args(self:anticipate("expression", "p argument"))
			end
		end
	end
	if args then
		self "pop"
		return {
			type = "call",
			table = t,
			key = name,
			args = args,
			token = rel,
		}
	end
	return self "pull"
end

function ast:expression()
	return self:assignexpression()
		or self:binop_or()
end

function ast:assignexpression()
	local rel = self "push"
	local left = self:post_only_expression()
	if not (left and islvalue(left)) then return self "pull" end
	local op = self()
	if compoundoperators[op.type] then
		op = op.type
		self(op)
	else op = false end
	if self "assign" then
		local right = self:anticipate "expression"
		self "pop"
		return op and {
			type = "compoundassign",
			left = left,
			right = right,
			op = op,
			token = rel,
		} or {
			type = "assign",
			left = left,
			right = right,
			token = rel,
		}
	end
	return self "pull"
end

local function binexprbuilder(funcname, callnext, ops)
	ast[funcname] = function(self)
		local rel = self "push"
		local left = assert(self[callnext], callnext)(self)
		if left then
			local b = false
			repeat
				b = false
				local rel = self()
				local op = ops[rel.type]
				if op then
					self(rel.type)
					b = true
					local right = self:anticipate(callnext, "right operand")
					left = {
						type = "binop",
						op = op,
						left = left,
						right = right,
						token = rel,
					}
				end
			until not b
			self "pop"
			return left
		end
		return self "pull"
	end
end

local function rightassociative_binexprbuilder(funcname, callnext, ops)
	local function func(self)
		local rel = self "push"
		local left = assert(self[callnext], callnext)(self)
		if left then
			local rel = self()
			local op = ops[rel.type]
			if op then
				self(rel.type)
				local right = func(self) -- self:anticipate(callnext, "right operand")
				left = {
					type = "binop",
					op = op,
					left = left,
					right = right,
					token = rel,
				}
			end
			self "pop"
			return left
		end
		return self "pull"
	end
	ast[funcname] = func
end

-- pow apparently has a higher precedence that the unary operators...
-- https://www.lua.org/manual/5.3/manual.html#3.4.8

binexprbuilder("binop_or", "binop_and", {['or']="or"})
binexprbuilder("binop_and", "compareop", {['and']="and"})
-- compareop
binexprbuilder("binop_bor", "binop_bxor", {bor="bor"})
binexprbuilder("binop_bxor", "binop_band", {bxor="bxor"})
binexprbuilder("binop_band", "binop_shift", {band="band"})
binexprbuilder("binop_shift", "binop_concat", {lshift="lshift",rshift="rshift",arshift="arshift"})
rightassociative_binexprbuilder("binop_concat", "binop_sum", {concat="concat"})
binexprbuilder("binop_sum", "binop_prod", {add="add",sub="sub"})
binexprbuilder("binop_prod", "pre_expression", {mul="mul",div="div",mod="mod",intdiv="intdiv"})
-- unary
-- pow
-- pre_expression

local compareops = {
	eq = "eq", ne = "ne",
	lt = "lt", gt = "gt",
	le = "le", ge = "ge",
}

function ast:compareop()
	local rel = self "push"
	local left = self:binop_bor()
	if left then
		local l = list()
		l(left)
		local b = false
		while true do
			local rel = self()
			local op = compareops[rel.type]
			if op then
				b = true
				self(rel.type)
				local right = self:anticipate("binop_bor")
				l(op)
				l(right)
			else break end
		end
		self "pop"
		if b then
			left = {
				type = "compare",
				value = l,
				token = rel,
				op = "compare",
			}
		end
		return left
	end
	return self "pull"
end

function ast:comma_separated_expressions()
	local rel = self "push"
	local args = list()
	local b = false
	repeat
		local arg = b and self:anticipate "expression" or self:expression()
		if not arg then
			if not b then return self "pull" end
			break
		end
		b = true
		args(arg)
	until not self "comma"
	self "pop"
	return args
end

function ast:literal()
	return self:numberliteral()
		or self:stringliteral()
		or self:tableliteral()
		or self:boolean()
		or self:nil_()
end

function ast:nil_()
	local rel = self()
	if self "nil" then
		return {
			type = "nil",
			token = rel,
		}
	end
end

function ast:boolean()
	local rel = self()
	local f = self "false"
	if f or self "true" then
		return {
			type = "bool",
			value = not f,
			token = rel,
		}
	end
end

function ast:tableliteral()
	local rel = self "push"
	if self "opentable" then
		local keys = list()
		local values = list()
		if not self "rbrace" then
			local lastindex = 0
			repeat
				if self "rbrace" then goto gotbrace end
				if self "lsquare" then
					local key = self:anticipate("expression", "key")
					self:expect("rsquare", "closing square bracket")
					self:expect("assign", "equals")
					local value = self:anticipate("expression", "value")
					keys(key)
					values(value)
				else
					self "push"
					local key = self:ident() or self:literal()
					if self "assign" then
						if key.type == "identifier" then
							-- this is a bit of a bodge, but it works
							key.type = "string"
						end
						self "pop"
						local value = self:anticipate("expression", "value")
						keys(key)
						values(value)
						if key.type == "numberliteral" then
							lastindex = key.value
						end
					else
						self "pull"
						local rel = self()
						local value = self:anticipate("expression", "value")
						lastindex = lastindex + 1
						keys {
							type = "number",
							value = lastindex,
							token = rel,
						}
						values(value)
					end
				end
			until not (self "comma" or self "semicolon")
			self:expect("rbrace", "closing brace")
			::gotbrace::
		end
		self "pop"
		return {
			type = "tableliteral",
			keys = keys,
			values = values,
			token = rel,
		}
	end
	return self "pull"
end

function ast:stringliteral()
	local rel = self "push"
	local str = self "string"
	if str then
		self "pop"
		return {
			type = "string",
			value = str,
			token = rel,
		}
	end
	return self "pull"
end

function ast:numberliteral()
	local rel = self "push"
	local number = self "number"
	if number then
		self "pop"
		return {
			type = "number",
			value = number,
			token = rel,
		}
	end
	return self "pull"
end

function ast:statements()
	local rel = self "push"
	if self "lbrace" then
		local l = list()
		while not self "rbrace" do
			local statement = self:anticipate("statement", "statement")
			if not statement then break end
			l(statement)
		end
		self "pop"
		return {
			type = "statements",
			body = l,
			token = rel,
		}
	end
	return self "pull"
end

function ast:functionstatement(ignorename)
	local rel = self "push"
	local glob = (not ignorename and self("ident", "glob"))
	if self "func" then
		local tablename = false
		local name = false
		local colon = false
		if not ignorename then
			name = self:expect("ident", "function name")
			if not glob then
				colon = self "colon"
				local implicitselffunc = colon and self().type == "lparen"
				if not implicitselffunc and (colon or self "dot") then
					tablename = name
					name = self:expect("ident", "function name")
				end
			end
		else
			colon = self "colon"
		end
		local params, vararg = self:parenparams()
		if not params then
			params, vararg = self:anticipate("noparenparams", "function parameters")
		end
		if colon then
			params:prepend "self"
		end
		local body = self:anticipate("statement", "function body")
		self "pop"
		return {
			type = "functionstatement",
			tablename = tablename,
			name = name,
			params = params,
			body = body,
			vararg = vararg or false,
			glob = glob,
			token = rel,
		}
	end
	return self "pull"
end

function ast:noparenparams()
	local rel = self "push"
	local params = list()
	local vararg = false
	repeat
		vararg = self "vararg"
		if vararg then
			local t = self()
			if t.type == "comma" then
				complain(self, "there may be no additional parameters after a vararg", t)
			end
			break
		end
		params(self:expect 'ident')
	until not self "comma"
	self "pop"
	return params, vararg
end

function ast:parenparams()
	local rel = self "push"
	if not self "lparen" then
		return self "pull"
	end
	local params = list()
	local vararg = false
	if not self "rparen" then
		repeat
			vararg = self "vararg"
			if vararg then
				local t = self()
				if t.type == "comma" then
					complain(self, "there may be no additional parameters after a vararg", t)
				end
				break
			end
			params(self:expect 'ident')
		until not self "comma"
		self:expect "rparen"
	end
	self "pop"
	return params, vararg
end

return function(tokens)
	local x = new(tokens)
	local r, e, p = x:file()
	assert(x.stack.n == 0, "unbalanced post-parse stack")
	return r, e, p
end

