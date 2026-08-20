-- sound.lua — audio hooks. Every hook silently no-ops when its file is missing,
-- so the game runs clean with an empty (or absent) Source/sounds/ folder.
--
-- Drop files into Source/sounds/ named exactly (no extension in code):
--   music    looping level track (ADPCM .wav preferred; .mp3 accepted)
--   thrust   loopable engine noise (.wav/.aiff only — sampleplayer can't do mp3)
--   crash, clear, maxspeed, record, bounce   one-shot SFX (.wav/.aiff)

local snd <const> = playdate.sound

Sound = {}

local music = nil -- module-level ref: a playing fileplayer must not be GC'd
local sp = {}

local SFX <const> = { "thrust", "crash", "clear", "maxspeed", "record", "bounce", "warp",
	"reset", "gateclose", "hover", "select", "merge" }

function Sound.init(debug)
	local found, missing = {}, {}
	for i = 1, #SFX do
		local name = SFX[i]
		sp[name] = snd.sampleplayer.new("sounds/" .. name)
		if sp[name] then found[#found + 1] = name else missing[#missing + 1] = name end
	end
	-- fileplayer.new never fails early; check the compiled file exists first
	if playdate.file.exists("sounds/music.pda") or playdate.file.exists("sounds/music.mp3") then
		music = snd.fileplayer.new("sounds/music")
		found[#found + 1] = "music"
	else
		missing[#missing + 1] = "music"
	end
	if debug then
		print("[sound] found: " .. (#found > 0 and table.concat(found, ",") or "none")
			.. " | missing: " .. (#missing > 0 and table.concat(missing, ",") or "none"))
	end
end

function Sound.musicStart()
	if music and not music:isPlaying() then
		music:play(0) -- 0 = loop forever
	end
end

function Sound.musicStop()
	if music and music:isPlaying() then
		music:stop()
	end
end

function Sound.thrust(on)
	local s = sp.thrust
	if not s then return end
	if on and not s:isPlaying() then
		s:play(0)
	elseif not on and s:isPlaying() then
		s:stop()
	end
end

local function oneShot(name)
	local s = sp[name]
	if s then s:play(1) end
end

function Sound.crash() oneShot("crash") end
function Sound.clear() oneShot("clear") end
function Sound.maxspeed() oneShot("maxspeed") end
function Sound.record() oneShot("record") end
function Sound.warp() oneShot("warp") end
function Sound.reset() oneShot("reset") end
function Sound.gateclose() oneShot("gateclose") end
function Sound.hover() oneShot("hover") end
function Sound.select() oneShot("select") end
function Sound.merge() oneShot("merge") end

function Sound.bounce(vol)
	local s = sp.bounce
	if not s then return end
	if vol < 0.15 then vol = 0.15 elseif vol > 1 then vol = 1 end
	s:setVolume(vol)
	s:play(1)
end
