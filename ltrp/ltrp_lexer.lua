local list = require((...):match("^(.-)[^%./\\]*$") .. "ltrp_list")

local function iswhitespace(c)
	return c == ' '
		or c == '\n'
		or c == '\t'
		or c == '\r'
end

local function isident(c, digit)
	return 'a' <= c and c <= 'z'
		or 'A' <= c and c <= 'Z'
		or (digit and '0' <= c and c <= '9')
		or c == '_'
end

local function digit(c, base)
	if base <= 36 then
		c = c:upper()
	end
	local d = c:byte()
	local n = ('0' <= c and c <= '9' and d - 0x30)
		or ('A' <= c and c <= 'Z' and d - 0x41 + 10)
		or ('a' <= c and c <= 'z' and d - 0x61 + 36)
	if n and n < base then
		return n
	end
	return nil
end

local function get(s, i, j)
	if j then
		s = s:sub(i, j-1)
		return #s < j-i and s .. ('\0'):rep(j-i-#s) or s
	else
		return i <= #s and s:sub(i,i) or '\0'
	end
end

local function makecomplaint(token, str)
	local src = token.sourcecode:match("[^\n\r]*", token.offset - token.col + 1):gsub('\t', ' ')
	return ("line %i: %s\n%s\n%s"):format(token.line, str or "error at", src, (" "):rep(token.col-1)..("~"):rep(math.max(#token.source, 1)))
end

local function token(sourcecode, line, offset, linestart, type, source, value, whitespace)
	return {
		sourcecode = sourcecode,
		line = line,
		offset = offset,
		col = offset - linestart + 1,
		source = source or false,
		type = type or false,
		whitespace = whitespace or false,
		value = value or false,
		makecomplaint = makecomplaint,
	}
end

local keywords = {
	['true'] = "true", ['false'] = "false", ['nil'] = "nil",
	['and'] = "and", ['or'] = "or", ['not'] = "not",
	['repeat'] = 'repeat', ['until'] = 'until',
	['if'] = 'if', ['elseif'] = "elseif", ['else'] = "else",
	['while'] = "while", ['for'] = "for",
	import = "import", use = "use",
	func = "func", ret = "ret",
}

local specialchars = {
	['{'] = "lbrace", ['}'] = "rbrace",
	['('] = "lparen", [')'] = "rparen",
	['['] = "lsquare", [']'] = "rsquare",
	[','] = "comma", ['.'] = "dot",
	[':'] = "colon", [';'] = "semicolon",
	['='] = "assign",
	
	['#'] = "len",
	
	['&&'] = "and", ['||'] = "or", ['!'] = "not",
	
	['&'] = "band", ['|'] = "bor", ['^'] = "bxor", ['~'] = "bnot",
	['<<'] = "lshift", ['>>'] = "rshift", ['>>>'] = "arshift",
	
	['@{'] = "opentable",
	
	['...'] = "vararg",
	['..'] = "concat",
	
	['+'] = "add", ['-'] = "sub",
	['*'] = "mul", ['/'] = "div", ['%'] = "mod",
	
	['++'] = "increment", ['--'] = "decrement",
	['**'] = "pow", ['//'] = "intdiv",
	['=='] = "eq",
	['~='] = "ne", ['!='] = "ne",
	['<'] = "lt", ['>'] = "gt",
	['<='] = "le", ['>='] = "ge",
}

local longest_specialchar = 0
for k,v in pairs(specialchars) do local l = #k if longest_specialchar < l then longest_specialchar = l end end

local function lex(src)
	local out = list()
	
	local line = 1
	local linestart = 1
	
	local inmultilinecomment = false
	
	local p = 1
	while p <= #src do
		local c = get(src, p)
		
		if inmultilinecomment or get(src, p, p+2) == '//' then -- singleline comment/end multiline comment
			while c ~= '\n' and c ~= '\r' and c ~= '\0' do
				if inmultilinecomment and get(src, p, p+2) == "*/" then
					p = p + 2
					inmultilinecomment = false
					goto cont
				end
				p = p + 1 
				c = get(src, p)
			end
			-- goto cont
			-- drop down to whitespace
		end
		
		if iswhitespace(c) then -- spaces/newlines
			local q = p
			while iswhitespace(c) do
				if c == '\n' or c == '\r' then
					if q ~= p then
						out(token(src, line, q, linestart, "space", get(src, q, p), nil, true))
						q = p
					end
					p = p + 1
					if c == '\r' and get(src, p) == '\n' then
						p = p + 1
					end
					out(token(src, line, q, linestart, "newline", get(src, q, p), nil, true))
					line = line + 1
					linestart = p
					q = p
				else
					p = p + 1
				end
				c = get(src, p)
			end
			if q ~= p then
				out(token(src, line, q, linestart, "space", get(src, q, p), nil, true))
				q = p
			end
			goto cont
		end
		
		if get(src, p, p+2) == '/*' then -- begin mutiline comment
			p = p + 2
			inmultilinecomment = true
			goto cont
		end
		
		if get(src, p, p+2) == '[[' then -- multiline string
			local qq = p
			p = p + 2
			local q = p
			while true do
				local cc = get(src, p, p+2)
				local c = get(src, p)
				local crlf = cc == '\r\n'
				if crlf or c == '\n' or c == '\r' then
					p = p + (crlf and 2 or 1)
					line = line + 1
					linestart = p
				elseif cc == ']]' then
					local pp = p
					p = p + 2
					local value = get(src, q, pp)
					c = value:sub(1, 1)
					cc = value:sub(1, 2)
					if cc == '\r\n' then value = value:sub(3)
					elseif c == '\n' or c == '\r' then value = value:sub(2)
					end
					out(token(src, line, q, linestart, "string", get(src, qq, p), value))
					goto cont
				else
					p = p + 1
				end
			end
		end
		
		do -- random chars
			local ident = src:match("^([%a_][%w_]*)", p)
			if ident and keywords[ident] then
				out(token(src, line, p, linestart, keywords[ident], ident))
				p = p + #ident
				goto cont
			end
			for i = longest_specialchar, 1, -1 do
				local s = get(src, p, p+i)
				local t = specialchars[s]
				if t then
					out(token(src, line, p, linestart, t, s))
					p = p + i
					goto cont
				end
			end
		end
		
		if isident(c, false) then
			local q = p
			while true do
				p = p + 1
				if not isident(get(src, p), true) then
					break
				end
			end
			local s = get(src, q, p)
			out(token(src, line, q, linestart, "ident", s, s))
			goto cont
		end
		
		if digit(c, 10) then
			local q = p
			local base = 10
			if c == '0' then
				local d = get(src, p + 1):lower()
				p = p + 2
				if     d == 'x' then base = 16
				elseif d == 'b' then base = 2
				elseif d == 'o' then base = 8
				elseif d == 'd' then base = 10
				elseif d == 'r' then
					d = get(src, p)
					base = assert(digit(d, 62), d) + 1
					p = p + 1
				else p = p - 2 end
			end
			local lo, hi = 0, 0
			local lct = 0
			local inlo = false
			while true do
				c = get(src, p)
				local n = digit(c, base)
				if n then
					if inlo then
						lo = lo * base + n
						lct = lct + 1
					else
						hi = hi * base + n
					end
				elseif c == '.' then
					if inlo then
						return nil, (("malformed number near:%q"):format(get(src, q, p)))
					else
						inlo = true
					end
				elseif c ~= '_' then
					break
				end
				p = p + 1
			end
			if inlo then
				hi = hi + lo * base ^ -lct
			end
			local source = get(src, q, p)
			out(token(src, line, q, linestart, "number", source, hi))
			goto cont
		end
		
		if c == '"' or c == "'" then
			local s = list()
			local terminator = c
			local begin = p
			local q = p + 1
			while true do
				p = p + 1
				c = get(src, p)
				if c == terminator then
					if q < p then
						s(get(src, q, p))
					end
					break
				elseif c == '\\' then
					if q < p then s(get(src, q, p)) end
					p = p + 1
					c = get(src, p)
					if c == '\\' then c = '\\'
					elseif c == 'n' then c = '\n'
					elseif c == 'r' then c = '\r'
					elseif c == 't' then c = '\t'
					elseif c == "'" then c = "'"
					elseif c == '"' then c = '"'
					-- elseif c == 'x' then c = ("x%02X"):format(tonumber(get(src, p+1, p+3), 16)) p=p+2
					elseif c == 'x' then c = string.char(tonumber(get(src, p+1, p+3), 16)) p=p+2
					else return nil, (("invalid string escape \\%s"):format(c)) end
					s(c)
					q = p + 1
				end
			end
			p = p + 1
			out(token(src, line, begin, linestart, "string", get(src, begin, p), table.concat(s)))
			goto cont
		end
		
		-- error(("%q"):format(src:sub(p, p+9)))
		do return nil, ("lexer: invalid character in source string %q (0x%02X)"):format(get(src, p), get(src, p):byte()), out end
		
		::cont::
	end
	
	out(token(src, line, p, linestart, "eof", ""))
	
	return out
end

return lex