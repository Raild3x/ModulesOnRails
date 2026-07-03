-- Spec file: must be excluded from discovery by the spec pattern.
return function(t)
	t.test("excluded", function() end)
end
