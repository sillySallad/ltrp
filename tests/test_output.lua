local lu = require 'tests.luaunit'
local ltrp = require 'ltrp'

local function tryCompile(src)
	local code, errors, component, partial = ltrp.compile(src)
	if not code then
		lu.fail(("compiler failed in component '%s'\n%s"):format(component, errors))
	end
	return code
end

local function trim(str)
	return str:match('^%s*(.-)%s*$')
end

local function filter(str)
	str = trim(str):gsub('\n%s+', '\n')
	str = str:gsub('\n', ' ')
	return str
end

local function assertOutput(input, expected)
	expected = filter(expected)
	if type(input) ~= 'table' then
		input = {input}
	end
	for _,v in ipairs(input) do
		lu.assertEquals(filter(tryCompile(v)), expected)
	end
end


TestOutput = {}

local function outputTest(testname, inputs, output)
    for k,v in ipairs(inputs) do
        local i = v
        TestOutput[("test_%s_%i"):format(testname, k)] = function(self)
            assertOutput(i, output)
        end
    end
end

outputTest("empty_function", {
	"func f();",
	"func f() {}",
}, "local f function f() end")

outputTest("simple_function_ret_number", {
	"func f() ret 42",
	"func f() ret 42;",
	"func f() { ret 42 }"
}, "local f function f() return 42 end")

-- function TestOutput:test_empty_function()
-- 	assertOutput({
-- 		"func f();"
-- 	}, "local f function f() end")
-- end


lu.run()
