-- menu.lua — orbital main menu + level select.
--
-- The whole UI is one continuous orbital system seen through a lerping camera:
-- PLAY/CONTINUE sits at the center, LEVEL SELECT and CREDITS orbit it, and the
-- three level tiers are rings further out that come into view as you climb.
-- Up/Down move between rings; Left/Right or the crank spin the cursor around the
-- focused ring and the nearest body wins it. A confirms, B backs out.
--
-- Text that can land on top of a white planet is drawn through outlineText so it
-- stays readable either way; glyphs ON a planet flip black/white with its fill.

local pd <const> = playdate
local gfx <const> = playdate.graphics
local floor <const> = math.floor
local ceil <const> = math.ceil
local sin <const> = math.sin
local cos <const> = math.cos
local sqrt <const> = math.sqrt
local abs <const> = math.abs
local min <const> = math.min
local rad <const> = math.rad
local PI <const> = math.pi
local TWO_PI <const> = 2 * math.pi

Menu = {}

local save = nil
local font = nil
local fontBold = nil

-- Title subtitles. Plain ASCII on purpose: font:drawTextAligned does NOT parse
-- the *bold* / _italic_ markup (only gfx.drawText does), and LaTeX backslash
-- sequences are eaten by Lua first. Keep each under ~44 chars to fit 400px.
local subtitles <const> = {
	"[Lat., living force.]",
	"1/2 rho v^2 + rho gh + P = constant",
	"v^2 = GM (2/r - 1/a)",
	"Leibniz was right.",
	"Energy is conserved. You are not.",
	"Mind the periapsis.",
}
local subIdx = 1
local titleImg = nil

-- ---- orbital layout (world units; the camera maps them to screen) ----
-- tier rings are derived from #Levels in Menu.init: ring N+1 sits 1.6x farther
-- out than ring N, so new level sets slot in without touching the layout
local R_WORLD = { [0] = 0, 108, 240 }
local TIER_RING = {}
local RING_TIER = {}
local NTIERS = 0
local PER_TIER <const> = 5
local TIER_GATE <const> = 4     -- clears needed in tier N to unlock tier N+1
local R_PLAY <const> = 22
local R_SELECT <const> = 16
local R_CREDITS <const> = 10
local R_LEVEL <const> = 16      -- on the focused ring
local R_LEVEL_NEAR <const> = 10 -- one ring away
local R_LEVEL_FAR <const> = 6   -- two or more rings away
local R_CREDITS_ZOOM <const> = 150
local FOCUS_PX <const> = 70     -- focused ring radius on screen, title
local FOCUS_PX_SEL <const> = 72 -- ... level select (its own square, right half)
local SPIN_RATE <const> = 2.4   -- rad/s, d-pad spin on the single-body center
local CAM_LERP <const> = 0.2
local SHIP_LERP <const> = 0.35
local DRIFT <const> = TWO_PI / 40 -- ring 1: one revolution per 40s
local TITLE_SCALE <const> = 1.35 -- wordmark blown up to run the screen height

local bodies = {}
local creditsBody = nil
local focusRing = 0
local cursorAng = 0
local shipAng = 0
local selBody = nil
local revealed = 2
local lastSel = nil
local sysT = 0
local zoomT = 0
local camX, camY, camSX, camSY, camScale = 0, 0, 200, 130, 0.65

-- ---- helpers ----
local function stats(i)
	return save and save.levels and save.levels[tostring(i)] or nil
end

local function clearedCount()
	local n = 0
	for i = 1, #Levels do
		local st = stats(i)
		if st and st.cleared then n = n + 1 end
	end
	return n
end

local function tierClearedCount(tier)
	local n = 0
	for k = 1, PER_TIER do
		local st = stats((tier - 1) * PER_TIER + k)
		if st and st.cleared then n = n + 1 end
	end
	return n
end

local function tierUnlocked(tier)
	if tier == 1 then return true end
	if save and save.unlockAll then return true end
	return tierClearedCount(tier - 1) >= TIER_GATE
end

function Menu.firstUncleared()
	for i = 1, #Levels do
		local st = stats(i)
		if not (st and st.cleared) then return i end
	end
	return 1
end

local function playLabel()
	local n = clearedCount()
	if n == 0 or n >= #Levels then return "PLAY" end
	return "CONTINUE"
end

-- inner rings drift faster (Kepler-ish), so the system reads as a real orbit
local function ringSpeed(ring)
	if ring == 0 then return 0 end
	local f = R_WORLD[1] / R_WORLD[ring]
	return DRIFT * f * sqrt(f)
end

local function bodyAngle(b)
	return b.ang0 + ringSpeed(b.ring) * sysT
end

local function bodyWorld(b)
	local r = R_WORLD[b.ring]
	if r == 0 then return 0, 0 end
	local a = bodyAngle(b)
	return r * cos(a), r * sin(a)
end

local function toScreen(wx, wy)
	return camSX + (wx - camX) * camScale, camSY + (wy - camY) * camScale
end

local function angDelta(a, b)
	local d = (a - b) % TWO_PI
	if d > PI then d = d - TWO_PI end
	return d
end

local function bodyRadius(b)
	if b.kind == "play" then return R_PLAY end
	if b.kind == "select" then return R_SELECT end
	if b.kind == "credits" then
		return R_CREDITS + (R_CREDITS_ZOOM - R_CREDITS) * zoomT
	end
	local d = b.ring - focusRing
	if d < 0 then d = -d end
	if d == 0 then return R_LEVEL end
	if d == 1 then return R_LEVEL_NEAR end
	return R_LEVEL_FAR
end

-- ang0 order is the ring order (every body on a ring shares one drift rate)
local function ringBodies()
	local list = {}
	for i = 1, #bodies do
		if bodies[i].ring == focusRing then list[#list + 1] = bodies[i] end
	end
	table.sort(list, function(p, q) return p.ang0 < q.ang0 end)
	return list
end

-- the body a ring lands on when you arrive from another ring: LEVEL SELECT on
-- the menu ring, lowest level on a tier. Deterministic, unlike "nearest to
-- wherever the cursor happened to be" once the system has drifted.
local function primaryBody(ring)
	local best = nil
	for i = 1, #bodies do
		local b = bodies[i]
		if b.ring == ring then
			if b.kind == "select" or b.kind == "play" then return b end
			if not best or (b.level and best.level and b.level < best.level) then best = b end
		end
	end
	return best
end

local function selectNearest()
	local best, bestd = nil, 1e9
	for i = 1, #bodies do
		local b = bodies[i]
		if b.ring == focusRing then
			local d = abs(angDelta(bodyAngle(b), cursorAng))
			if d < bestd then best, bestd = b, d end
		end
	end
	selBody = best
end

-- one press = one body over
local function stepSelection(dir)
	local list = ringBodies()
	if #list < 2 then return end
	local idx = 1
	for i = 1, #list do
		if list[i] == selBody then idx = i end
	end
	cursorAng = bodyAngle(list[((idx - 1 + dir) % #list) + 1])
end

-- 4-way 1px outline: readable over a white planet or the black background
local function outlineText(f, text, x, y, align)
	gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
	f:drawTextAligned(text, x - 1, y, align)
	f:drawTextAligned(text, x + 1, y, align)
	f:drawTextAligned(text, x, y - 1, align)
	f:drawTextAligned(text, x, y + 1, align)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	f:drawTextAligned(text, x, y, align)
end

local function container(x, y, w, h)
	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.94, gfx.image.kDitherTypeBayer8x8)
	gfx.fillRect(x, y, w, h)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawRect(x, y, w, h)
end

-- ---- setup ----
function Menu.init(saveRef)
	save = saveRef
	math.randomseed(pd.getSecondsSinceEpoch())
	font = gfx.getSystemFont()
	fontBold = gfx.getSystemFont("bold")
	titleImg = gfx.image.new("images/title") -- serif wordmark, baked at build time
	NTIERS = ceil(#Levels / PER_TIER)
	for tier = 1, NTIERS do
		local ring = tier + 1
		R_WORLD[ring] = 240 * (1.6 ^ (tier - 1))
		TIER_RING[tier] = ring
		RING_TIER[ring] = tier
	end
	bodies = {}
	bodies[#bodies + 1] = { ring = 0, ang0 = 0, kind = "play" }
	bodies[#bodies + 1] = { ring = 1, ang0 = 0, kind = "select" }
	creditsBody = { ring = 1, ang0 = PI, kind = "credits" }
	bodies[#bodies + 1] = creditsBody
	bodies[#bodies + 1] = { ring = 1, ang0 = PI / 2, kind = "editor" }
	for tier = 1, NTIERS do
		for k = 1, PER_TIER do
			local lvl = (tier - 1) * PER_TIER + k
			if lvl <= #Levels then
				bodies[#bodies + 1] = {
					ring = TIER_RING[tier],
					ang0 = (k - 1) * TWO_PI / PER_TIER - PI / 2,
					kind = "level", tier = tier, level = lvl,
				}
			end
		end
	end
end

-- `from` is the state we are backing out of, so the cursor lands on the body
-- that was just opened instead of snapping home
function Menu.enterTitle(from)
	pd.getCrankChange() -- discard stale crank
	if from == "select" or from == "credits" or from == "custom" then
		focusRing = 1
		local want = (from == "credits") and "credits" or (from == "custom") and "editor" or "select"
		for i = 1, #bodies do
			if bodies[i].kind == want then cursorAng = bodyAngle(bodies[i]) end
		end
	else
		focusRing = 0
		cursorAng = 0
	end
	selectNearest()
	lastSel = selBody -- adopt silently; entering a screen is not a hover
	if selBody then shipAng = bodyAngle(selBody) end
	if #subtitles > 1 then
		subIdx = ((subIdx - 1 + math.random(#subtitles - 1)) % #subtitles) + 1
	end
end

function Menu.enterSelect()
	pd.getCrankChange()
	revealed = (save and save.unlockAll) and NTIERS or min(2, NTIERS)
	focusRing = TIER_RING[1]
	local pb = primaryBody(focusRing) -- always open on the tier's first level
	if pb then cursorAng = bodyAngle(pb) end
	selectNearest()
	lastSel = selBody
	shipAng = cursorAng
end

function Menu.enterCredits()
	pd.getCrankChange()
end

-- ---- drawing ----
local function drawBody(b, state)
	local wx, wy = bodyWorld(b)
	local sx, sy = toScreen(wx, wy)
	local r = bodyRadius(b)
	local selected = (b == selBody)
	local locked = (b.kind == "level") and not tierUnlocked(b.tier)

	-- tier shade echoes the gameplay density ramp: tier 1 white, tier 2 gray,
	-- tier 3 black. Selecting darkens one more step; the bold ring does the
	-- real work of marking the selection.
	local lightOnDark = selected or locked
	gfx.setColor(gfx.kColorWhite)
	if locked then
		-- hollow: you can see it, you cannot fly it yet
		gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
		gfx.drawCircleAtPoint(sx, sy, r)
		gfx.setColor(gfx.kColorWhite)
	elseif b.kind == "level" and b.tier == 3 then
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(sx, sy, r)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawCircleAtPoint(sx, sy, r) -- rim, or it vanishes into the sky
		lightOnDark = true
	elseif b.kind == "level" and b.tier == 2 then
		gfx.setDitherPattern(selected and 0.8 or 0.42, gfx.image.kDitherTypeBayer8x8)
		gfx.fillCircleAtPoint(sx, sy, r)
		gfx.setColor(gfx.kColorWhite)
	elseif b.kind == "level" and b.tier == 4 then
		-- moving-bodies tier: gray like tier 2 but wearing its own tiny moon
		gfx.setDitherPattern(selected and 0.8 or 0.42, gfx.image.kDitherTypeBayer8x8)
		gfx.fillCircleAtPoint(sx, sy, r)
		gfx.setColor(gfx.kColorWhite)
		local ma = sysT * 2.2 + b.ang0
		gfx.fillCircleAtPoint(sx + (r + 5) * cos(ma), sy + (r + 5) * sin(ma), 2)
	elseif selected then
		gfx.setDitherPattern(0.72, gfx.image.kDitherTypeBayer8x8)
		gfx.fillCircleAtPoint(sx, sy, r)
		gfx.setColor(gfx.kColorWhite)
	else
		gfx.fillCircleAtPoint(sx, sy, r)
	end
	if selected then
		gfx.setLineWidth(3)
		gfx.drawCircleAtPoint(sx, sy, r + 5)
		gfx.setLineWidth(1)
	end

	-- glyphs are white on a dark/hollow body, black on a light one
	if b.kind == "level" then
		if r >= 14 then
			gfx.setImageDrawMode(lightOnDark and gfx.kDrawModeFillWhite or gfx.kDrawModeFillBlack)
			font:drawTextAligned(tostring(b.level), sx - 3, sy - font:getHeight() / 2, kTextAlignment.center)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		end
		local st = stats(b.level)
		if st and st.cleared and r >= 10 then
			local cx, cy = sx + r * 0.5, sy + r * 0.42
			gfx.setColor(lightOnDark and gfx.kColorWhite or gfx.kColorBlack)
			gfx.setLineWidth(2)
			gfx.drawLine(cx - 4, cy, cx - 1, cy + 3)
			gfx.drawLine(cx - 1, cy + 3, cx + 4, cy - 5)
			gfx.setLineWidth(1)
			gfx.setColor(gfx.kColorWhite)
		end
	elseif state == "title" then
		local label = "CREDITS"
		if b.kind == "play" then label = playLabel()
		elseif b.kind == "select" then label = "LEVEL SELECT"
		elseif b.kind == "editor" then label = "LEVEL EDITOR" end
		if b.ring == 0 then
			Draw.bigText(label, sx, sy - 8) -- sits on the planet itself
			return
		end
		local lx, ly
		do
			-- park the label just outside the ring, clamped clear of the chrome
			local a = bodyAngle(b)
			lx = sx + cos(a) * (r + 12)
			ly = sy + sin(a) * (r + 12) - 8
			if lx < 54 then lx = 54 elseif lx > 346 then lx = 346 end
			if ly < 30 then ly = 30 elseif ly > 190 then ly = 190 end
		end
		outlineText(font, label, lx, ly, kTextAlignment.center)
	end
end

local function drawInfoPanel()
	-- borderless and bled to the edges; the dither is a backdrop, not a box
	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.94, gfx.image.kDitherTypeBayer8x8)
	gfx.fillRect(0, 0, 158, 240)
	gfx.setColor(gfx.kColorWhite)
	if not selBody or selBody.kind ~= "level" then return end
	local i = selBody.level
	local lv = Levels[i]
	Draw.bigText("L" .. i, 79, 14)
	-- names run to 17 chars, so wrap at the last space that fits the column
	local name = lv.name
	if fontBold:getTextWidth(name) <= 140 then
		Draw.bigText(name, 79, 40)
	else
		local cut = nil
		for pos in name:gmatch("()%s") do
			if fontBold:getTextWidth(name:sub(1, pos - 1)) <= 140 then cut = pos end
		end
		if cut then
			Draw.bigText(name:sub(1, cut - 1), 79, 40)
			Draw.bigText(name:sub(cut + 1), 79, 62)
		else
			Draw.bigText(name, 79, 40)
		end
	end
	if not tierUnlocked(selBody.tier) then
		local need = TIER_GATE - tierClearedCount(selBody.tier - 1)
		outlineText(font, "LOCKED", 79, 106, kTextAlignment.center)
		outlineText(font, "clear " .. need .. " more", 79, 128, kTextAlignment.center)
		outlineText(font, "in tier " .. (selBody.tier - 1), 79, 148, kTextAlignment.center)
		Draw.prompt("@B back", 79, 202, font)
		return
	end
	local st = stats(i)
	if st and st.cleared then
		outlineText(font, "CLEARED", 79, 106, kTextAlignment.center)
		outlineText(font, string.format("best %.1fs", st.bestTime or 0), 79, 128, kTextAlignment.center)
		outlineText(font, string.format("%d%% fuel", floor(100 * (st.bestFuel or 0) / lv.fuel)),
			79, 148, kTextAlignment.center)
	else
		outlineText(font, "not cleared", 79, 106, kTextAlignment.center)
	end
	Draw.prompt("@A play", 79, 178, font)
	Draw.prompt("@B back", 79, 202, font)
end

local function drawCredits()
	local wx, wy = bodyWorld(creditsBody)
	local sx, sy = toScreen(wx, wy)
	local r = bodyRadius(creditsBody)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillCircleAtPoint(sx, sy, r)
	if zoomT < 0.55 then return end -- hold the text until the planet fills the side
	gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
	fontBold:drawTextAligned("VIS-VIVA", sx + 30, sy - 24, kTextAlignment.center)
	font:drawTextAligned("CREDITS", sx + 30, sy + 2, kTextAlignment.center)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	font:drawTextAligned("Matias Ortiz", 296, 72, kTextAlignment.center)
	font:drawTextAligned("Mauricio Luzardo", 296, 92, kTextAlignment.center)
	font:drawTextAligned("Built with Claude", 296, 122, kTextAlignment.center)
	font:drawTextAligned("Chiptune by Claude", 296, 142, kTextAlignment.center)
	Draw.prompt("@B back", 296, 184, font)
end

local function drawCursor()
	if not selBody then return end
	local ox, oy = toScreen(0, 0)
	local rr = R_WORLD[focusRing] * camScale
	local dist
	if focusRing == 0 then
		dist = bodyRadius(selBody) + 13   -- lone central body: sit outside it
	else
		dist = rr - bodyRadius(selBody) - 16 -- tuck inside the ring, nose out
	end
	local x, y = ox + dist * cos(shipAng), oy + dist * sin(shipAng)
	-- nose always points AT the selected planet: inward from outside the
	-- center body, outward from inside a ring
	local hx, hy
	if focusRing == 0 then
		hx, hy = -cos(shipAng), -sin(shipAng)
	else
		hx, hy = cos(shipAng), sin(shipAng)
	end
	local px, py = -hy, hx
	gfx.setColor(gfx.kColorWhite)
	gfx.fillTriangle(x + 9 * hx, y + 9 * hy,
		x - 6 * hx + 4 * px, y - 6 * hy + 4 * py,
		x - 6 * hx - 4 * px, y - 6 * hy - 4 * py)
end

local function drawScene(state)
	if state == "credits" then
		drawCredits()
		return
	end
	local ox, oy = toScreen(0, 0)
	local topRing = (state == "select") and TIER_RING[revealed] or 1
	for ring = 1, topRing do
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.72, gfx.image.kDitherTypeBayer8x8)
		gfx.drawCircleAtPoint(ox, oy, R_WORLD[ring] * camScale)
	end
	gfx.setColor(gfx.kColorWhite)
	if state == "select" then
		gfx.fillCircleAtPoint(ox, oy, 4) -- home, where the main menu lives
	end
	for i = 1, #bodies do
		local b = bodies[i]
		local show
		if state == "select" then
			show = (b.ring >= 2 and b.ring <= topRing)
		else
			show = (b.ring <= topRing)
		end
		if show then drawBody(b, state) end
	end
	drawCursor()
	if state == "title" then
		if titleImg then
			-- the wordmark is opaque white-on-black, so the ambient FillWhite
			-- draw mode would flatten it into a solid block: punch the black out
			gfx.setImageDrawMode(gfx.kDrawModeBlackTransparent)
			titleImg:drawRotated(24, 120, -90, TITLE_SCALE) -- reads bottom-to-top
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		end
		-- with no wordmark to stand on the left, fall back to a stacked header
		local subY = 6
		if not titleImg then
			outlineText(fontBold, "VIS-VIVA", 224, 6, kTextAlignment.center)
			subY = 26
		end
		outlineText(font, subtitles[subIdx], 224, subY, kTextAlignment.center)
		Draw.prompt("@A select    up/down: orbits", 224, 216, font)
	else
		drawInfoPanel()
	end
end

-- ---- per-frame ----
-- `crankDeg` is the frame's crank movement, read once by main and handed down.
-- ================= custom-levels orbital menu =================
-- Same visual language as the level select, but the rings belong to the
-- player: each ring holds up to 5 custom levels plus a dashed '+' body that
-- creates a new one. Up from the outermost ring (if it has at least one
-- level) opens a fresh ring; Down from an empty outermost ring removes it.
local CSLOTS <const> = 6 -- 5 levels + the '+' body
local cRing = 1
local cBodies = {}
local cCursor = 0
local cShip = 0
local cSel = nil
local cLastSel = nil

local function customRingCount()
	return (save and save.customRingCount) or 1
end

local function ensureRingRadius(ring)
	for r = 2, ring do
		if not R_WORLD[r] then
			R_WORLD[r] = 240 * (1.6 ^ (r - 2))
		end
	end
end

local function rebuildCustom()
	cBodies = {}
	local counts = {}
	for i, cl in ipairs((save and save.customLevels) or {}) do
		local r = cl.ring or 1
		counts[r] = (counts[r] or 0) + 1
		if counts[r] < CSLOTS then
			cBodies[#cBodies + 1] = { ring = r, slot = counts[r], kind = "clevel", idx = i }
		end
	end
	for r = 1, customRingCount() do
		local n = counts[r] or 0
		if n < CSLOTS then
			cBodies[#cBodies + 1] = { ring = r, slot = n + 1, kind = "plus" }
		end
		ensureRingRadius(r + 1)
	end
end

local function cAngle(b)
	return (b.slot - 1) * TWO_PI / CSLOTS - PI / 2 + ringSpeed(b.ring + 1) * sysT
end

local function cSelectNearest()
	local best, bd = nil, 1e9
	for i = 1, #cBodies do
		local b = cBodies[i]
		if b.ring == cRing then
			local d = abs(angDelta(cAngle(b), cCursor))
			if d < bd then best, bd = b, d end
		end
	end
	cSel = best
end

function Menu.enterCustom()
	pd.getCrankChange()
	cRing = 1
	rebuildCustom()
	cSelectNearest()
	if cSel then
		cCursor = cAngle(cSel)
		cShip = cCursor
	end
	cLastSel = cSel
end

local function ringLevelCount(r)
	local n = 0
	for _, b in ipairs(cBodies) do
		if b.ring == r and b.kind == "clevel" then n = n + 1 end
	end
	return n
end

local function updateCustom(crankDeg)
	local dt = 1 / 30
	sysT = sysT + dt
	local action = nil

	if pd.buttonJustPressed(pd.kButtonUp) then
		if cRing < customRingCount() then
			cRing = cRing + 1
			cCursor = cShip
		elseif ringLevelCount(cRing) >= 1 then
			save.customRingCount = customRingCount() + 1
			pd.datastore.write(save)
			rebuildCustom()
			cRing = cRing + 1
			cCursor = cShip
		end
	elseif pd.buttonJustPressed(pd.kButtonDown) then
		if cRing > 1 then
			-- leaving an empty outermost ring dissolves it
			if cRing == customRingCount() and ringLevelCount(cRing) == 0 and customRingCount() > 1 then
				save.customRingCount = customRingCount() - 1
				pd.datastore.write(save)
				rebuildCustom()
			end
			cRing = cRing - 1
			cCursor = cShip
		end
	end

	if pd.buttonJustPressed(pd.kButtonLeft) or pd.buttonJustPressed(pd.kButtonRight) then
		local dir = pd.buttonJustPressed(pd.kButtonLeft) and -1 or 1
		local list = {}
		for _, b in ipairs(cBodies) do
			if b.ring == cRing then list[#list + 1] = b end
		end
		table.sort(list, function(pq, q) return pq.slot < q.slot end)
		if #list > 1 then
			local idx = 1
			for i = 1, #list do
				if list[i] == cSel then idx = i end
			end
			cCursor = cAngle(list[((idx - 1 + dir) % #list) + 1])
		end
	end
	cCursor = cCursor + rad(crankDeg or 0) + ringSpeed(cRing + 1) * dt
	cSelectNearest()
	if cSel ~= cLastSel then
		if cLastSel then Sound.hover() end
		cLastSel = cSel
	end

	if pd.buttonJustPressed(pd.kButtonA) and cSel then
		if cSel.kind == "plus" then
			action = { go = "newlevel", ring = cRing }
		else
			action = { go = "clevel", idx = cSel.idx }
		end
	elseif pd.buttonJustPressed(pd.kButtonB) then
		action = { go = "title" }
	end

	-- camera: focused custom ring fills the right-hand square
	local ts = FOCUS_PX_SEL / R_WORLD[cRing + 1]
	camX = camX + (0 - camX) * CAM_LERP
	camY = camY + (0 - camY) * CAM_LERP
	camSX = camSX + (280 - camSX) * CAM_LERP
	camSY = camSY + (120 - camSY) * CAM_LERP
	camScale = camScale + (ts - camScale) * CAM_LERP

	if cSel then
		cShip = cShip + angDelta(cAngle(cSel), cShip) * SHIP_LERP
	end

	-- draw
	local ox, oy = toScreen(0, 0)
	for r = 1, customRingCount() do
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.72, gfx.image.kDitherTypeBayer8x8)
		gfx.drawCircleAtPoint(ox, oy, R_WORLD[r + 1] * camScale)
	end
	gfx.setColor(gfx.kColorWhite)
	gfx.fillCircleAtPoint(ox, oy, 4)
	for _, b in ipairs(cBodies) do
		local rr = R_WORLD[b.ring + 1] * camScale
		local a = cAngle(b)
		local x, y = ox + rr * cos(a), oy + rr * sin(a)
		local br = (b.ring == cRing) and 16 or 9
		local selected = (b == cSel)
		gfx.setColor(gfx.kColorWhite)
		if b.kind == "plus" then
			gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
			gfx.drawCircleAtPoint(x, y, br)
			gfx.setColor(gfx.kColorWhite)
			gfx.drawLine(x - br * 0.45, y, x + br * 0.45, y)
			gfx.drawLine(x, y - br * 0.45, x, y + br * 0.45)
		else
			if selected then
				gfx.setDitherPattern(0.72, gfx.image.kDitherTypeBayer8x8)
				gfx.fillCircleAtPoint(x, y, br)
				gfx.setColor(gfx.kColorWhite)
			else
				gfx.fillCircleAtPoint(x, y, br)
			end
			local cl = save.customLevels[b.idx]
			if cl and cl.cleared and br >= 10 then
				gfx.setColor(selected and gfx.kColorWhite or gfx.kColorBlack)
				gfx.setLineWidth(2)
				gfx.drawLine(x + br * 0.5 - 4, y + br * 0.42, x + br * 0.5 - 1, y + br * 0.42 + 3)
				gfx.drawLine(x + br * 0.5 - 1, y + br * 0.42 + 3, x + br * 0.5 + 4, y + br * 0.42 - 5)
				gfx.setLineWidth(1)
				gfx.setColor(gfx.kColorWhite)
			end
		end
		if selected then
			gfx.setLineWidth(3)
			gfx.drawCircleAtPoint(x, y, br + 5)
			gfx.setLineWidth(1)
		end
	end
	-- ship cursor inside the focused ring, nose out
	local rr = R_WORLD[cRing + 1] * camScale
	local dist = rr - 16 - 16
	local x, y = ox + dist * cos(cShip), oy + dist * sin(cShip)
	local hx, hy = cos(cShip), sin(cShip)
	local px, py = -hy, hx
	gfx.setColor(gfx.kColorWhite)
	gfx.fillTriangle(x + 9 * hx, y + 9 * hy,
		x - 6 * hx + 4 * px, y - 6 * hy + 4 * py,
		x - 6 * hx - 4 * px, y - 6 * hy - 4 * py)

	-- info panel, borderless left column
	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.94, gfx.image.kDitherTypeBayer8x8)
	gfx.fillRect(0, 0, 158, 240)
	gfx.setColor(gfx.kColorWhite)
	if cSel and cSel.kind == "clevel" then
		local cl = save.customLevels[cSel.idx]
		Draw.bigText(cl.name or "UNTITLED", 79, 30)
		if cl.cleared then
			outlineText(font, "CLEARED", 79, 106, kTextAlignment.center)
			outlineText(font, string.format("best %.1fs", cl.bestTime or 0), 79, 128, kTextAlignment.center)
		else
			outlineText(font, "not cleared", 79, 106, kTextAlignment.center)
		end
		Draw.prompt("@A play", 79, 178, font)
		Draw.prompt("@B back", 79, 202, font)
	else
		Draw.bigText("CREATE", 79, 30)
		Draw.bigText("NEW LEVEL", 79, 54)
		outlineText(font, "ring " .. cRing .. " / " .. customRingCount(), 79, 106, kTextAlignment.center)
		if cRing == customRingCount() and ringLevelCount(cRing) >= 1 then
			outlineText(font, "up: new ring", 79, 128, kTextAlignment.center)
		end
		Draw.prompt("@A create", 79, 178, font)
		Draw.prompt("@B back", 79, 202, font)
	end
	return action
end

function Menu.update(state, crankDeg)
	if state == "custom" then
		return updateCustom(crankDeg)
	end
	local dt = 1 / 30
	if state ~= "credits" then sysT = sysT + dt end
	zoomT = zoomT + (((state == "credits") and 1 or 0) - zoomT) * 0.25

	local action = nil
	if state == "credits" then
		if pd.buttonJustPressed(pd.kButtonB) then action = { go = "title" } end
	else
		local inSelect = (state == "select")
		local loRing = inSelect and TIER_RING[1] or 0
		local hiRing = inSelect and TIER_RING[min(revealed, NTIERS)] or 1
		local prevRing = focusRing
		if pd.buttonJustPressed(pd.kButtonUp) and focusRing < hiRing then
			focusRing = focusRing + 1
		elseif pd.buttonJustPressed(pd.kButtonDown) and focusRing > loRing then
			focusRing = focusRing - 1
		end
		if focusRing ~= prevRing then
			if focusRing == 0 then
				-- the center holds one body at a fixed angle, so snapping to it
				-- would throw the aim away; keep it and climb back out to it
			elseif prevRing == 0 then
				-- climbing out of the center: keep whichever body we were facing
				selectNearest()
				if selBody then cursorAng = bodyAngle(selBody) end
			else
				local pb = primaryBody(focusRing)
				if pb then cursorAng = bodyAngle(pb) end
			end
		end
		if inSelect then
			local t = RING_TIER[focusRing]
			if t and t + 1 > revealed then revealed = min(NTIERS, t + 1) end
		end
		if focusRing == 0 then
			-- one body here, so nothing to step to: spin freely like the crank
			if pd.buttonIsPressed(pd.kButtonLeft) then cursorAng = cursorAng - SPIN_RATE * dt end
			if pd.buttonIsPressed(pd.kButtonRight) then cursorAng = cursorAng + SPIN_RATE * dt end
		else
			if pd.buttonJustPressed(pd.kButtonLeft) then stepSelection(-1) end
			if pd.buttonJustPressed(pd.kButtonRight) then stepSelection(1) end
		end
		-- carry the ring's own drift so a body cannot slip out from under the cursor
		cursorAng = cursorAng + rad(crankDeg or 0) + ringSpeed(focusRing) * dt
		selectNearest()
		if selBody ~= lastSel then
			if lastSel then Sound.hover() end
			lastSel = selBody
		end

		if pd.buttonJustPressed(pd.kButtonA) and selBody then
			local k = selBody.kind
			if k == "play" then
				action = { go = "continue" }
			elseif k == "select" then
				action = { go = "select" }
			elseif k == "credits" then
				action = { go = "credits" }
			elseif k == "editor" then
				action = { go = "custom" }
			elseif k == "level" and tierUnlocked(selBody.tier) then
				action = { go = "level", idx = selBody.level }
			end
		elseif pd.buttonJustPressed(pd.kButtonB) and inSelect then
			action = { go = "title" }
		end
	end

	-- camera targets: the whole UI is one system, only the framing changes
	local tx, ty, tsx, tsy, ts
	if state == "credits" then
		tx, ty = bodyWorld(creditsBody)
		tsx, tsy, ts = 40, 120, FOCUS_PX / R_WORLD[1]
	elseif state == "select" then
		tx, ty = 0, 0
		tsx, tsy, ts = 280, 120, FOCUS_PX_SEL / R_WORLD[focusRing]
	else
		tx, ty = 0, 0
		tsx, tsy, ts = 224, 117, FOCUS_PX / R_WORLD[1]
	end
	camX = camX + (tx - camX) * CAM_LERP
	camY = camY + (ty - camY) * CAM_LERP
	camSX = camSX + (tsx - camSX) * CAM_LERP
	camSY = camSY + (tsy - camSY) * CAM_LERP
	camScale = camScale + (ts - camScale) * CAM_LERP

	local shipTarget = nil
	if focusRing == 0 then
		shipTarget = cursorAng -- lone central body: follow the cursor itself
	elseif selBody then
		shipTarget = bodyAngle(selBody)
	end
	if shipTarget then
		shipAng = shipAng + angDelta(shipTarget, shipAng) * SHIP_LERP
	end

	drawScene(state)
	return action
end
