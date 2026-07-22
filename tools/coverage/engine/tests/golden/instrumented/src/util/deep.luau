local __covrt=require("../_cov");local _COV=__covrt.cov;local _COVD=__covrt.covd;local _COVC=__covrt.covd;local _COVL=__covrt.covl; --!tm-coverage-instrumented
-- Nested file: exercises cov_require_path depth 1 and cross-file dense ids.

_COV(83);
local Deep = {}

_COV(84);
function Deep.double(n: number): number
	_COV(85);
	_COV(86);
	return n * 2
end

_COV(87);
return Deep
