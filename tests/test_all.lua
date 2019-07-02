local lu = require 'tests.luaunit'

local run = lu.run
lu.run = function() end

require 'tests.test_output'

run()
