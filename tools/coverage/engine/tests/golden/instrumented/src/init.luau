local __covrt=require("@self/_cov");local _COV=__covrt.cov;local _COVD=__covrt.covd;local _COVC=__covrt.covd;local _COVL=__covrt.covl; --!tm-coverage-instrumented
-- Coverage fixture: exercises each collector feature once.
-- Golden files pin probe positions -- do not reformat this file.

_COV(1);
local M = {}

type Foo = { n: number }

_COV(2);
local x = 1 _COV(3); local y = 2

_COV(4);
function M.add(a: number, b: number): number
	_COV(5);
	_COV(6);
	if _COVD(7, _COVC(9, a > 0) and _COVC(11, b > 0)) then
		_COV(13);
		return a + b
	else
		_COV(14);
		return a - b
	end
end

_COV(15);
function M:_reset()
	_COV(16);
	_COV(17);
	local total = 0
	local __covL20 = 0; _COV(18);
	for i = 1, 3 do
		_COV(19);
		__covL20 += 1; total += x + i
	end; _COVL(20, __covL20)
	_COV(23);
	for i = 1, 10 do end
	_COV(24);
	return total
end

_COV(25);
local function helper(n: number): number
	_COV(26);
	_COV(27);
	if _COVD(28, n > 10) then
		_COV(30);
		return 10
	elseif _COVD(31, n > 5) then
		_COV(33);
		return 5
	end
	_COV(34);
	return n
end

_COV(35);
local cb = function(): number
	_COV(36);
	_COV(37);
	return helper(y)
end

_COV(38);
function M.drain(list: { number }): number
	_COV(39);
	_COV(40);
	local i = #list
	local __covL45 = 0; _COV(41);
	while _COVD(42, i > 0) do
		_COV(44);
		__covL45 += 1; i -= 1
	end; _COVL(45, __covL45)
	local __covL50 = 0; _COV(48);
	repeat
		_COV(49);
		__covL50 += 1; i += 1
	until _COVD(53, i >= 1); _COVL(50, __covL50)
	_COV(55);
	return cb()
end

_COV(56);
function M.each(items: { number }, f: (number) -> ())
	_COV(57);
	_COV(58);
	table.sort(items, function(a, b)
		_COV(59);
		_COV(60);
		return a < b
	end)
	local __covL63 = 0; _COV(61);
	for _, v in items do
		_COV(62);
		__covL63 += 1; f(v)
	end; _COVL(63, __covL63)
end

_COV(66);
function M.gated(service): number
	_COV(67);
	_COV(68);
	if _COVD(69, service:IsRunning()) then
		_COV(71);
		return 1
	end
	_COV(72);
	return 0
end

_COV(73);
function M.boom()
	_COV(74);
	_COV(75);
	error("boom")
	_COV(76);
	x = 99
end

_COV(77);
if false then
	_COV(78);
	x = -1
end

_COV(79);
if true then
	_COV(80);
	y = 2
else
	_COV(81);
	y = -2
end

_COV(82);
return M
