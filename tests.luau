local fs = require("@lune/fs")
local io = require("@lune/stdio")
local process = require("@lune/process")

local tiniest = require("@tiniest/tiniest_for_lune").configure({
	snapshot_path = "./test/__snapshots__",
	save_snapshots = false,
}) 

local lastPackageFile = "./test/last_tested_package.txt"

-- Function to read the last package name from the file
local function readLastPackage()
    if fs.isFile(lastPackageFile) then
        local content = fs.readFile(lastPackageFile)
        return content and content:match("^%s*(.-)%s*$") -- Trim whitespace
    end
    return nil
end

-- Function to write the last package name to the file
local function writeLastPackage(packageName)
    fs.writeFile(lastPackageFile, packageName)
end

-- Prompt the user for the directory name
local dirName = io.prompt("text", "Enter the name of a directory inside lib: ")

-- Handle "last" input
if not dirName or dirName == "last" or dirName == "" then
    dirName = readLastPackage()
    if not dirName or dirName == "" then
        print("No previous package name found.")
        process.exit(1)
    else
        print("Using last package name: " .. dirName)
    end
else
    writeLastPackage(dirName)
end

if not dirName or dirName == "" then
    print("Invalid directory name.")
    process.exit(1)
end

local basePath = "lib/" .. dirName

-- Function to collect `.spec` files recursively
local function collectSpecFiles(path, result)
    local entries = fs.readDir(path)
    for _, entry in pairs(entries) do
        local fullPath = path .. "/" .. entry
        local isDir = fs.isDir(fullPath)
        if not isDir and entry:match("%.spec") then
            table.insert(result, fullPath)
        elseif isDir then
            collectSpecFiles(fullPath, result)
        end
    end
end

if not fs.isDir(basePath) then
    print("Directory does not exist: " .. basePath)
    process.exit(1)
end

local specFiles = {}
collectSpecFiles(basePath, specFiles)

local tests = tiniest.collect_tests(function()
	local describe = tiniest.describe

	local function describe_from_file(name: string)
		describe(string.gsub(name, ".luau", ""), function()
			require(name)(tiniest)
		end)
	end

    -- Output the collected files
    if #specFiles > 0 then
        for _, file in pairs(specFiles) do
            describe_from_file(file)
        end
    else
        print("No .spec files found in " .. basePath)
    end
end)


tiniest.run_tests(tests, {})
