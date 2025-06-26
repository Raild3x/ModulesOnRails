-- I use this file to test the speed of stuff

local t = os.clock()
for index = 1, 1000000 do
    -- local left, right, smallest = index * 2, index * 2 + 1, index
    local left2, right2, smallest2 = bit32.lshift(index, 2), bit32.bor(bit32.lshift(index, 2), 1), index
end
print(os.clock() - t)