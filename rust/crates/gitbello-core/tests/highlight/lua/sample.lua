#!/usr/bin/env lua
--- A small inventory module.
-- Line comment with no doc.
--[[ A long comment on one line ]]
--[==[ with a level ]==]
local M = {}

local MAX <const> = 0x10
local path = [[C:\no\escapes]]
local level = [=[it's [[nested]] ]=]

function M.new(name, count)
  local self = setmetatable({}, { __index = M })
  self.name = name or "item\n"
  self.count = count or 1.5e3
  return self
end

local function total(items)
  local sum = 0
  for _, item in ipairs(items) do
    if item.count > 0 and not item.hidden then
      sum = sum + item.count
    elseif item.count == nil then
      goto continue
    end
    ::continue::
  end
  repeat sum = sum - 1 until sum < 10
  while false do break end
  return sum, #items, 'done'
end

print(total({ M.new("a", 2) }), _G, true)
return M
local text = [==[
a long string ]] still
]==]
--[[ a long
comment ]] print(text)
