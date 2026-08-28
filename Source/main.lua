-- Gravity Golf — crank to aim, hold B to burn, break the wall at speed.

import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/crank"
import "CoreLibs/keyboard"

import "physics"
import "levels"
import "draw"
import "sound"
import "menu"
import "editor"

local pd <const> = playdate
local gfx <const> = playdate.graphics
local sqrt <const> = math.sqrt
local floor <const> = math.floor
local rad <const> = math.rad
local sin <const> = math.sin
local cos <const> = math.cos
local max <const> = math.max
local min <const> = math.min
local random <const> = math.random

-- ===================== TUNABLES =====================
DEBUG = true
THRUST = 80 -- px/s^2
RESTITUTION = 0.9 -- wall bounce
NSUB = 4 -- physics substeps per frame
H = (1 / 30) / NSUB -- fixed physics dt (s)
FUEL_BONUS = 0.5 -- score weight of leftover fuel
DPAD_RATE = 180 -- deg/s heading adjust on d-pad
DEAD_TIME = 0.7 -- s before auto-restart
SHAKE_CRASH = 6 -- px shake magnitude on crash
SHAKE_WIN = 4 -- px shake magnitude on wall break
SHAKE_DECAY = 0.85
SHAKE_MIN = 0.5
MAXSPEED_REARM = 0.9 -- re-arm the vmin cue below this fraction of vmin
GATE_LATCH = 1 / 16 -- s the gate stays open after touching vmin
K_DENSITY = 100 -- gm = K_DENSITY * density * r^3
D_SOLID = 1.8 -- density <= this renders solid white (all of L1-5)
D_BLACKHOLE = 6.0 -- density >= this renders as a black hole
TRAP_WINDOW = 2.0 -- s: re-entering the wormhole you just exited = crash
CAM_LERP = 0.12 -- camera follow factor per frame
CAM_LOOKAHEAD = 0.4 -- s of velocity lead
NSUB_DENSE = 8 -- substeps when a dense body is present
NSUB_DENSE_D = 2.4 -- max body density >= this bumps NSUB
-- ====================================================

pd.display.setRefreshRate(30)
gfx.setBackgroundColor(gfx.kColorBlack)
gfx.setImageDrawMode(gfx.kDrawModeFillWhite) -- white text on black

local state = "title" -- title | select | credits | custom | playing | dead | won | editor
local curLevel = 1
local level = nil
local ship = nil
local frame = 0
local deadTimer = 0
-- Crank persistence: set once here, moved only by the d-pad. Never reseeded on
-- level load, so the ship's heading always tracks the physical crank position.
local dpadOffset = 0
local impactSpeed, score = 0, 0
local energy0 = nil -- debug energy baseline (reset on thrust/bounce)
local save = nil
local runTime = 0
local runTopSpeed = 0
local maxspeedArmed = true
local recordPlayed = false
local shakeMag = 0
local pendingState = nil -- set by system-menu callbacks, consumed in update
local camX, camY = 0, 0
-- what the loaded level IS: builtin index, custom save slot, or an editor test run
local levelCtx = { kind = "builtin", idx = 1 }
local gateWasOpen = false
local gateSounded = false

local function loadSave()
	save = pd.datastore.read() or {}
	save.levels = save.levels or {}
end

-- string keys: sparse integer keys don't survive the JSON round-trip
local function saveWin(i, time, fuelLeft, topSpd)
	local k = tostring(i)
	local st = save.levels[k] or {}
	st.cleared = true
	st.bestTime = st.bestTime and min(st.bestTime, time) or time
	st.bestFuel = st.bestFuel and max(st.bestFuel, fuelLeft) or fuelLeft
	st.topSpeed = max(st.topSpeed or 0, topSpd)
	save.levels[k] = st
	pd.datastore.write(save)
end

local function startShake(m)
	shakeMag = m
end

local function applyShake()
	if shakeMag >= SHAKE_MIN then
		pd.display.setOffset((random() * 2 - 1) * shakeMag, (random() * 2 - 1) * shakeMag)
		shakeMag = shakeMag * SHAKE_DECAY
	elseif shakeMag > 0 then
		shakeMag = 0
		pd.display.setOffset(0, 0)
	end
end

local function updateCamera(snap)
	if not level.bounds then
		camX, camY = 0, 0
		return
	end
	local tx = ship.x + ship.vx * CAM_LOOKAHEAD - 200
	local ty = ship.y + ship.vy * CAM_LOOKAHEAD - 120
	if tx < 0 then tx = 0 elseif tx > level.bw - 400 then tx = level.bw - 400 end
	if ty < 0 then ty = 0 elseif ty > level.bh - 240 then ty = level.bh - 240 end
	if snap then
		camX, camY = tx, ty
	else
		camX = camX + (tx - camX) * CAM_LERP
		camY = camY + (ty - camY) * CAM_LERP
	end
end

local function loadLevelData(lv, ctx)
	levelCtx = ctx
	-- deep-copy: runtime fields (clones, bw/bh, merge flags) must never attach
	-- to authored tables in Levels[] or to level data living in the datastore
	level = Editor.deepcopy(lv)
	-- runtime CLONES of every body: free planets move, merge, and grow, so the
	-- authored tables must survive untouched for the next restart
	level.allBodies = {}
	level.planetBodies = {}
	level.freeBodies = {}
	level.wormholeBodies = {}
	level.mergeEvent = nil
	level.planetWarped = false
	for _, src in ipairs(level.bodies) do
		local gm = src.gm or (K_DENSITY * src.density * src.r * src.r * src.r)
		local b = {
			x = src.x, y = src.y, r = src.r, gm = gm,
			density = src.density or (gm / (K_DENSITY * src.r * src.r * src.r)),
			orbit = src.orbit, free = src.free,
			vx = src.vx or 0, vy = src.vy or 0,
			exitTimer = 0, exitHoleId = 0,
		}
		level.allBodies[#level.allBodies + 1] = b
		level.planetBodies[#level.planetBodies + 1] = b
		if b.free then
			level.freeBodies[#level.freeBodies + 1] = b
		end
	end
	if level.wormholes then
		for k, wh in ipairs(level.wormholes) do
			local gm = K_DENSITY * wh.density * wh.r * wh.r * wh.r
			local ea = { x = wh.ax, y = wh.ay, r = wh.r, gm = gm, density = wh.density, wormhole = true, id = 2 * k - 1, orbit = wh.orbitA }
			local eb = { x = wh.bx, y = wh.by, r = wh.r, gm = gm, density = wh.density, wormhole = true, id = 2 * k, orbit = wh.orbitB }
			ea.twin, eb.twin = eb, ea
			level.allBodies[#level.allBodies + 1] = ea
			level.allBodies[#level.allBodies + 1] = eb
			level.wormholeBodies[#level.wormholeBodies + 1] = ea
			level.wormholeBodies[#level.wormholeBodies + 1] = eb
		end
	end
	Physics.attach(level.allBodies)
	-- per-level substep count (black holes / dense wells need finer steps)
	local maxD = 0
	for _, b in ipairs(level.allBodies) do
		if b.density > maxD then maxD = b.density end
	end
	NSUB = (maxD >= NSUB_DENSE_D) and NSUB_DENSE or 4
	H = (1 / 30) / NSUB
	level.bw = level.bounds and level.bounds.w or 400
	level.bh = level.bounds and level.bounds.h or 240
	Physics.simT = 0
	local s = level.ship
	ship = {
		x = s.x, y = s.y, vx = s.vx, vy = s.vy,
		heading = 0, hx = 0, hy = -1,
		fuel = level.fuel, bounced = false, bounceSpeed = 0,
		exitTimer = 0, exitHoleId = 0, warped = false, gateTimer = 0,
	}
	gateWasOpen = false
	gateSounded = false
	Draw.resetTrail()
	state = "playing"
	energy0 = nil
	runTime = 0
	runTopSpeed = 0
	maxspeedArmed = true
	recordPlayed = false
	shakeMag = 0
	pd.display.setOffset(0, 0)
	updateCamera(true)
	Sound.musicStart()
end

local function loadLevel(i)
	curLevel = i
	local src = (save.levelOverrides and save.levelOverrides[tostring(i)]) or Levels[i]
	loadLevelData(src, { kind = "builtin", idx = i })
end

-- restart whatever is currently loaded, whatever kind it is
local function reloadLevel()
	if levelCtx.kind == "builtin" then
		loadLevel(levelCtx.idx)
	elseif levelCtx.kind == "custom" then
		loadLevelData(save.customLevels[levelCtx.idx].data, levelCtx)
	else
		loadLevelData(Editor.workingLevel(), { kind = "test" })
	end
end

local function updateHeading()
	if pd.buttonIsPressed(pd.kButtonLeft) then
		dpadOffset = dpadOffset - DPAD_RATE / 30
	end
	if pd.buttonIsPressed(pd.kButtonRight) then
		dpadOffset = dpadOffset + DPAD_RATE / 30
	end
	local h = (pd.getCrankPosition() + dpadOffset) % 360
	ship.heading = h
	local r = rad(h)
	ship.hx, ship.hy = sin(r), -cos(r) -- 0 deg = up, clockwise on screen
end

local function gotoMenu(target)
	Sound.thrust(false)
	Sound.musicStop()
	shakeMag = 0
	pd.display.setOffset(0, 0)
	gfx.setDrawOffset(0, 0)
	if target == "select" then
		Menu.enterSelect()
	elseif target == "credits" then
		Menu.enterCredits()
	elseif target == "custom" then
		Menu.enterCustom()
	else
		Menu.enterTitle(state)
	end
	state = target
end

-- ---- boot ----
loadSave()
Sound.init(DEBUG)
Menu.init(save)
Menu.enterTitle()

local sysmenu = pd.getSystemMenu()

-- the OS allows 3 custom items, so the pause menu swaps wholesale between the
-- game set, the editor set, and the playtest set. Playtest is the editor set
-- with the one item that makes no sense mid-run ("play level" -- you already
-- are) swapped for the way back out of it.
local function setSysMenu(mode)
	sysmenu:removeAllMenuItems()
	if mode == "editor" or mode == "test" then
		sysmenu:addMenuItem("save level", function() pendingState = "edSave" end)
		if mode == "test" then
			sysmenu:addMenuItem("continue editing", function() pendingState = "edReturn" end)
		else
			sysmenu:addMenuItem("play level", function() pendingState = "edPlay" end)
		end
		sysmenu:addMenuItem("exit editor", function() pendingState = "edExit" end)
	else
		sysmenu:addMenuItem("level select", function() pendingState = "select" end)
		sysmenu:addMenuItem("edit level", function()
			if level then pendingState = "edit" end
		end)
		-- cheat: reveal and unlock every tier, for playtesting and demos
		sysmenu:addCheckmarkMenuItem("unlock all", save.unlockAll or false, function(v)
			save.unlockAll = v
			pd.datastore.write(save)
		end)
	end
end
setSysMenu("game")

local function gotoEditor()
	Sound.thrust(false)
	Sound.musicStop()
	shakeMag = 0
	pd.display.setOffset(0, 0)
	gfx.setDrawOffset(0, 0)
	setSysMenu("editor")
	state = "editor"
end

local function enterEditor()
	if not level then return end
	if levelCtx.kind == "test" then
		gotoEditor() -- the working copy is already open in the editor
		return
	end
	local src, ctx
	if levelCtx.kind == "custom" then
		local cl = save.customLevels[levelCtx.idx]
		src = cl.data
		ctx = { kind = "custom", idx = levelCtx.idx, ring = cl.ring }
	else
		src = (save.levelOverrides and save.levelOverrides[tostring(curLevel)]) or Levels[curLevel]
		ctx = { kind = "builtin", idx = curLevel }
	end
	Editor.open(src, ctx)
	gotoEditor()
end

local function exitEditor()
	local ctx = Editor.ctx()
	setSysMenu("game")
	if ctx and ctx.kind == "builtin" then
		loadLevel(ctx.idx)
	elseif ctx and ctx.kind == "custom" and ctx.idx then
		levelCtx = { kind = "custom", idx = ctx.idx }
		reloadLevel()
	else
		gotoMenu("custom") -- brand-new level abandoned before its first save
	end
end

-- save flow: the system keyboard names the level; OK commits, cancel aborts.
-- Dev loop: saving a BUILTIN level writes a datastore override (plays
-- immediately) and dumps ready-to-paste levels.lua source to the console;
-- saving one with an EMPTY name deletes the override (revert to shipped).
local function editorSave()
	pd.keyboard.keyboardWillHideCallback = function(ok)
		pd.keyboard.keyboardWillHideCallback = nil
		if not ok then return end
		local name = pd.keyboard.text or ""
		local ctx = Editor.ctx()
		if ctx.kind == "builtin" then
			if name == "" then
				if save.levelOverrides then save.levelOverrides[tostring(ctx.idx)] = nil end
				Editor.flash("REVERTED TO ORIGINAL")
			else
				Editor.setName(name)
				save.levelOverrides = save.levelOverrides or {}
				save.levelOverrides[tostring(ctx.idx)] = Editor.workingLevel()
				print("-- paste into levels.lua (replaces L" .. ctx.idx .. "):")
				print(Editor.serialize())
				Editor.flash("SAVED + LUA IN CONSOLE")
			end
		else
			if name == "" then name = "UNTITLED" end
			Editor.setName(name)
			save.customLevels = save.customLevels or {}
			if ctx.idx then
				save.customLevels[ctx.idx].name = name
				save.customLevels[ctx.idx].data = Editor.workingLevel()
			else
				save.customLevels[#save.customLevels + 1] = {
					name = name, ring = ctx.ring or 1, data = Editor.workingLevel(),
				}
				ctx.idx = #save.customLevels
			end
			print("-- custom level source:")
			print(Editor.serialize())
			Editor.flash("SAVED")
		end
		pd.datastore.write(save)
	end
	pd.keyboard.show((Editor.name() ~= "UNTITLED") and Editor.name() or "")
end

function pd.gameWillTerminate()
	pd.datastore.write(save)
end

function pd.gameWillSleep()
	pd.datastore.write(save)
end

function pd.gameWillPause()
	local img = gfx.image.new(400, 240, gfx.kColorBlack)
	gfx.pushContext(img)
	gfx.setDrawOffset(0, 0)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawText("*VIS-VIVA*", 16, 24)
	if state == "editor" then
		gfx.drawText("dpad: move cursor", 16, 56)
		gfx.drawText("A: grab / add", 16, 76)
		gfx.drawText("crank: adjust value", 16, 96)
		gfx.drawText("*EDITING*", 16, 128)
		gfx.drawText(Editor.name(), 16, 148)
	else
		gfx.drawText("crank / left-right: aim", 16, 56)
		gfx.drawText("B or Up (hold): burn", 16, 76)
		gfx.drawText("A or Down: restart", 16, 96)
		if level then
			-- only builtin levels have a number and builtin stats; custom and
			-- editor-test levels carry neither (and may have no name at all yet)
			local name = level.name or "CUSTOM"
			if levelCtx.kind == "builtin" then
				gfx.drawText("*L" .. curLevel .. " " .. name .. "*", 16, 128)
				local st = save.levels[tostring(curLevel)]
				if st and st.cleared then
					gfx.drawText(string.format("best %.1fs", st.bestTime or 0), 16, 148)
					gfx.drawText(string.format("best fuel %d%%", floor(100 * (st.bestFuel or 0) / level.fuel)), 16, 168)
					gfx.drawText(string.format("top speed %d", floor(st.topSpeed or 0)), 16, 188)
				else
					gfx.drawText("not cleared yet", 16, 148)
				end
			elseif levelCtx.kind == "custom" then
				gfx.drawText("*" .. name .. "*", 16, 128)
				local cl = save.customLevels and save.customLevels[levelCtx.idx]
				if cl and cl.cleared then
					gfx.drawText(string.format("best %.1fs", cl.bestTime or 0), 16, 148)
				else
					gfx.drawText("not cleared yet", 16, 148)
				end
			else
				gfx.drawText("*EDITOR TEST*", 16, 128)
				gfx.drawText(name, 16, 148)
			end
		end
	end
	gfx.popContext()
	pd.setMenuImage(img)
end

function playdate.update()
	gfx.clear(gfx.kColorBlack)
	frame = frame + 1

	-- system-menu requests (callbacks fire before gameWillResume)
	if pendingState then
		local p = pendingState
		pendingState = nil
		if p == "select" then
			gotoMenu("select")
		elseif p == "restart" then
			reloadLevel()
		elseif p == "edit" then
			enterEditor()
		elseif p == "edSave" then
			editorSave()
		elseif p == "edPlay" then
			loadLevelData(Editor.workingLevel(), { kind = "test" })
			setSysMenu("test")
		elseif p == "edExit" then
			exitEditor()
		elseif p == "edReturn" then
			gotoEditor()
		end
	end

	applyShake()

	if state == "editor" then
		Editor.update()
		if DEBUG then
			pd.drawFPS(378, 228)
		end
		return
	end

	-- Menus own the getCrankTicks singleton (read exactly once per frame here);
	-- gameplay reads absolute crank position instead, so they never interact.
	if state == "title" or state == "select" or state == "credits" or state == "custom" then
		local crankDeg = pd.getCrankChange()
		local action = Menu.update(state, crankDeg)
		if action then
			-- backing out gets its own voice, distinct from a confirm
			if action.go == "title" then Sound.reset() else Sound.select() end
			if action.go == "level" then
				loadLevel(action.idx)
			elseif action.go == "continue" then
				loadLevel(Menu.firstUncleared())
			elseif action.go == "clevel" then
				loadLevelData(save.customLevels[action.idx].data, { kind = "custom", idx = action.idx })
			elseif action.go == "newlevel" then
				Editor.open({}, { kind = "custom", idx = nil, ring = action.ring })
				gotoEditor()
			else
				gotoMenu(action.go)
			end
		end
		if DEBUG then
			pd.drawFPS(378, 228)
		end
		return
	end

	local thrusting = false
	-- The system keyboard draws over a still-running game loop (Editor.update
	-- already bails for this reason). Naming a level from a playtest would
	-- otherwise leave the ship flying into a planet while you type, so freeze
	-- input and physics and fall through to the draw pass.
	local kbdUp = pd.keyboard.isVisible()

	if kbdUp then
		Sound.thrust(false)
	elseif state == "playing" then
		if pd.buttonJustPressed(pd.kButtonA) or pd.buttonJustPressed(pd.kButtonDown) then
			Sound.reset()
			reloadLevel()
		end
		updateHeading()
		thrusting = (pd.buttonIsPressed(pd.kButtonB) or pd.buttonIsPressed(pd.kButtonUp))
			and ship.fuel > 0
		Sound.thrust(thrusting)
		local ev, evSpeed = Physics.frame(ship, level, thrusting)
		updateCamera()
		runTime = runTime + 1 / 30
		if frame % 2 == 0 then
			Draw.recordTrail(ship.x, ship.y)
		end

		local speed = sqrt(ship.vx * ship.vx + ship.vy * ship.vy)
		runTopSpeed = max(runTopSpeed, speed)

		if ship.bounced then
			Sound.bounce(min(1, (ship.bounceSpeed or 0) / level.vmin))
			energy0 = nil
			ship.bounced = false
		end
		if ship.warped then
			Sound.warp()
			energy0 = nil -- teleport legitimately changes orbital energy
			ship.warped = false
		end
		if level.mergeEvent then
			-- planets collided and combined: radiating ring + shake + boom
			Draw.addMergeRing(level.mergeEvent.x, level.mergeEvent.y)
			startShake(SHAKE_CRASH)
			Sound.merge()
			energy0 = nil -- the field just changed shape
			level.mergeEvent = nil
		end
		if level.planetWarped then
			Sound.warp()
			level.planetWarped = false
		end

		-- gate cues follow the LATCHED state, so open/close always pairs with
		-- what the wall is actually doing on screen
		local gateNow = speed >= level.vmin or ship.gateTimer > 0
		if gateNow and not gateWasOpen then
			if maxspeedArmed then
				Sound.maxspeed()
				maxspeedArmed = false
				gateSounded = true
			end
		elseif gateWasOpen and not gateNow and gateSounded then
			Sound.gateclose()
			gateSounded = false
		end
		gateWasOpen = gateNow
		if not maxspeedArmed and speed < MAXSPEED_REARM * level.vmin then
			maxspeedArmed = true
		end
		if not recordPlayed then
			local st = (levelCtx.kind == "builtin") and save.levels[tostring(curLevel)] or nil
			if st and (st.topSpeed or 0) > 0 and speed > st.topSpeed then
				Sound.record()
				recordPlayed = true
			end
		end

		if ev == "crash" then
			state = "dead"
			deadTimer = DEAD_TIME
			Draw.burst(ship.x, ship.y)
			Sound.thrust(false)
			Sound.musicStop()
			Sound.crash()
			startShake(SHAKE_CRASH)
		elseif ev == "win" then
			state = "won"
			impactSpeed = evSpeed
			runTopSpeed = max(runTopSpeed, evSpeed)
			score = floor(evSpeed + FUEL_BONUS * ship.fuel)
			Draw.burst(ship.x, ship.y)
			Sound.thrust(false)
			Sound.musicStop()
			Sound.clear()
			startShake(SHAKE_WIN)
			if levelCtx.kind == "builtin" then
				saveWin(curLevel, runTime, ship.fuel, runTopSpeed)
			elseif levelCtx.kind == "custom" then
				local cl = save.customLevels[levelCtx.idx]
				if cl then
					cl.cleared = true
					cl.bestTime = cl.bestTime and min(cl.bestTime, runTime) or runTime
					pd.datastore.write(save)
				end
			end
		end

		if DEBUG then
			if thrusting then
				energy0 = nil
			elseif frame % 30 == 0 then
				local e = Physics.energy(ship, level)
				if not energy0 then
					energy0 = e
				else
					print(string.format("E=%.1f rel=%+.2e", e, (e - energy0) / math.abs(energy0)))
				end
			end
		end
	elseif state == "dead" then
		deadTimer = deadTimer - 1 / 30
		if deadTimer <= 0 or pd.buttonJustPressed(pd.kButtonA) or pd.buttonJustPressed(pd.kButtonB)
			or pd.buttonJustPressed(pd.kButtonUp) or pd.buttonJustPressed(pd.kButtonDown) then
			reloadLevel()
		end
	elseif state == "won" then
		if pd.buttonJustPressed(pd.kButtonB) or pd.buttonJustPressed(pd.kButtonUp) then
			if levelCtx.kind == "test" then
				pendingState = "edReturn"
			elseif levelCtx.kind == "custom" then
				gotoMenu("custom")
			elseif curLevel >= #Levels then
				gotoMenu("select")
			else
				loadLevel(curLevel + 1)
			end
		elseif pd.buttonJustPressed(pd.kButtonA) or pd.buttonJustPressed(pd.kButtonDown) then
			Sound.reset()
			reloadLevel()
		end
	end

	-- scene: world pass (under camera offset) then screen pass
	local speed = sqrt(ship.vx * ship.vx + ship.vy * ship.vy)
	local gateOpen = speed >= level.vmin or (ship.gateTimer or 0) > 0
	gfx.setDrawOffset(-camX, -camY)
	Draw.bounds(level)
	Draw.planets(level, Physics.simT)
	Draw.wormholes(level, frame)
	Draw.mergeRings(1 / 30)
	if state ~= "won" then
		Draw.wall(level, gateOpen)
	end
	Draw.trail()
	if state == "dead" then
		Draw.particles(1 / 30)
	else
		Draw.ship(ship, thrusting, frame)
	end
	if state == "won" then
		Draw.particles(1 / 30)
	end
	gfx.setDrawOffset(0, 0)
	if state == "dead" then
		Draw.bigText("CRASHED", 200, 106)
	end
	if state == "won" then
		Draw.bigText("BREACH!", 200, 86)
		Draw.bigText("impact " .. floor(impactSpeed) .. " + fuel " .. floor(FUEL_BONUS * ship.fuel), 200, 108)
		Draw.bigText(string.format("SCORE %d   %.1fs", score, runTime), 200, 130)
		local nextLabel = "@B next    @A retry"
		if levelCtx.kind == "test" then
			nextLabel = "@B back to editor    @A retry"
		elseif levelCtx.kind == "custom" then
			nextLabel = "@B level menu    @A retry"
		elseif curLevel >= #Levels then
			nextLabel = "@B level select    @A retry"
		end
		Draw.prompt(nextLabel, 200, 156)
	else
		Draw.goalArrow(level, gateOpen, camX, camY)
	end
	Draw.hud(ship, level, speed, (levelCtx.kind == "builtin") and curLevel or nil, runTime)
	if kbdUp then
		Draw.nameField(pd.keyboard.text, pd.keyboard.left and pd.keyboard.left() or 200, frame)
	end
	if DEBUG then
		pd.drawFPS(378, 228)
	end
end
