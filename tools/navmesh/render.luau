--!strict
--[=[
	Screenshot loop for the navmesh packages: DrawList -> SVG -> PNG.

	Usage (from the repo root):
		lune run tools/navmesh/render.luau <scene-module> <out-dir> [--no-png]

	<scene-module> is a Luau module path (relative to the repo root, without `.luau`) that
	returns `{ { Name: string, List: DrawList, Layers: { string }?, Width: number?, Height: number? } }`.
	Each scene is written to `<out-dir>/<Name>.svg`, then rasterized to `<out-dir>/<Name>.png`
	with headless Edge so it can be inspected as an image.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")

local SvgBackend = require("../../lib/constraineddelaunaydebug/src/SvgBackend")

local EDGE_PATH = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
local DEFAULT_SIZE = 800
-- Edge's headless window includes no chrome, but give the page a margin so nothing is clipped.
local WINDOW_MARGIN_PX = 0

type Scene = {
	Name: string,
	List: SvgBackend.DrawList,
	Layers: { string }?,
	Width: number?,
	Height: number?,
}

local args = process.args
local sceneModule = args[1]
local outDir = args[2]
local skipPng = table.find(args, "--no-png") ~= nil
if not sceneModule or not outDir then
	error("usage: lune run tools/navmesh/render.luau <scene-module> <out-dir> [--no-png]", 0)
end

-- Resolve the scene module relative to the repo root (this file is two levels down).
local dynRequire: any = require
local scenes: { Scene } = dynRequire("../../" .. sceneModule)

if not fs.isDir(outDir) then
	fs.writeDir(outDir)
end

local cwd = process.cwd:gsub("\\", "/")
for _, scene in scenes do
	local width = scene.Width or DEFAULT_SIZE
	local height = scene.Height or DEFAULT_SIZE
	local svg = SvgBackend.Render(scene.List, {
		Width = width,
		Height = height,
		Layers = scene.Layers,
		Title = scene.Name,
	})
	local svgPath = `{outDir}/{scene.Name}.svg`
	fs.writeFile(svgPath, svg)

	if skipPng then
		print(`[render] {svgPath}`)
		continue
	end

	local absOut = if outDir:match("^%a:") then outDir else `{cwd}/{outDir}`
	local pngPath = `{absOut}/{scene.Name}.png`
	local result = process.exec(EDGE_PATH, {
		"--headless",
		"--disable-gpu",
		"--hide-scrollbars",
		`--window-size={width + WINDOW_MARGIN_PX},{height + WINDOW_MARGIN_PX}`,
		`--screenshot={pngPath}`,
		`file:///{absOut}/{scene.Name}.svg`,
	})
	if not result.ok or not fs.isFile(pngPath) then
		error(`[render] Edge failed for {scene.Name} (code {result.code}):\n{result.stderr}`, 0)
	end
	print(`[render] {pngPath}`)
end
