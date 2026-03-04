local Class = {}
Class.__index = Class

local function makeInstance(proto, ...)
	local self = setmetatable({}, proto)
	if self.init then
		self:init(...)
	end
	return self
end

local function makeChild(base)
	local child = {}
	child.__index = child
	child.super = base

	setmetatable(child, { __index = base })

	function child.new(...)
		return makeInstance(child, ...)
	end

	function child.extend()
		return makeChild(child)
	end

	return child
end

function Class.new(...)
	return makeInstance(Class, ...)
end

function Class.extend()
	return makeChild(Class)
end

return Class