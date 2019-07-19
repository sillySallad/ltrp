

local mt = {}
mt.__index = mt

local function new()
	return setmetatable({n=0}, mt)
end

function mt.add(self, x)
	local n = self.n + 1
	self.n, self[n] = n, x
	return self
end

function mt.prepend(self, x)
	local n = self.n + 1
	self.n = n
	for i = n, 2, -1 do
		self[i] = self[i-1]
	end
	self[1] = x
	return self
end

function mt.__call(self, x)
	return self:add(x)
end

return new

