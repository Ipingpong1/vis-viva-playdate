-- draw.lua — immediate-mode rendering. Black screen, white ink, no sprites.

local gfx <const> = playdate.graphics
local sqrt <const> = math.sqrt
local sin <const> = math.sin
local cos <const> = math.cos

Draw = {}

-- ---- trail (preallocated ring buffer, recorded every 2nd frame by main) ----
local TRAIL_N <const> = 48
local trailX, trailY = table.create(TRAIL_N, 0), table.create(TRAIL_N, 0)
local trailCount, trailIdx = 0, 0

function Draw.resetTrail()
	trailCount, trailIdx = 0, 0
end

function Draw.recordTrail(x, y)
	trailIdx = (trailIdx % TRAIL_N) + 1
	trailX[trailIdx] = x
	trailY[trailIdx] = y
	if trailCount < TRAIL_N then trailCount = trailCount + 1 end
end

function Draw.trail()
	gfx.setColor(gfx.kColorWhite)
	for k = 1, trailCount do -- k=1 oldest
		local age = trailCount - k
		local skip = (age < 16) and 1 or ((age < 32) and 2 or 4)
		if k % skip == 0 then
			local i = ((trailIdx - trailCount + k - 1) % TRAIL_N) + 1
			gfx.drawPixel(trailX[i], trailY[i])
		end
	end
end

-- ---- ship + thrust flame ----
function Draw.ship(ship, thrusting, frame)
	local x, y, hx, hy = ship.x, ship.y, ship.hx, ship.hy
	local px, py = -hy, hx
	gfx.setColor(gfx.kColorWhite)
	gfx.fillTriangle(
		x + 9 * hx, y + 9 * hy,
		x - 6 * hx + 4 * px, y - 6 * hy + 4 * py,
		x - 6 * hx - 4 * px, y - 6 * hy - 4 * py)
	if thrusting then
		local tail = (frame % 2 == 0) and 12 or 16
		gfx.fillTriangle(
			x - 6 * hx + 2.5 * px, y - 6 * hy + 2.5 * py,
			x - 6 * hx - 2.5 * px, y - 6 * hy - 2.5 * py,
			x - tail * hx, y - tail * hy)
	end
end

-- ---- planets (drawn at positionAt(t), so on-rails planets render for free) ----
-- Density ramp: darker = denser. d <= D_SOLID -> solid white (all of L1-5);
-- mid densities -> progressively darker dither; d >= D_BLACKHOLE -> black
-- hole: black disc + 1px white event-horizon ring (the BH-exclusive marker).
-- (Dither alpha is inverted with white color — documented SDK bug.)
function Draw.planets(level, t)
	local bodies = level.planetBodies or level.bodies
	for i = 1, #bodies do
		local b = bodies[i]
		local bx, by = b:positionAt(t)
		local d = b.density or 1
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer8x8) -- 25% halo
		gfx.drawCircleAtPoint(bx, by, b.r * 2.5)
		if d >= D_BLACKHOLE then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(bx, by, b.r)
			gfx.setColor(gfx.kColorWhite)
			gfx.drawCircleAtPoint(bx, by, b.r)
		elseif d <= D_SOLID then
			gfx.setColor(gfx.kColorWhite)
			gfx.fillCircleAtPoint(bx, by, b.r)
		else
			gfx.setColor(gfx.kColorWhite)
			local pat = (d <= 3.2) and 0.3 or ((d <= 4.6) and 0.55 or 0.75)
			gfx.setDitherPattern(pat, gfx.image.kDitherTypeBayer8x8)
			gfx.fillCircleAtPoint(bx, by, b.r)
			gfx.setColor(gfx.kColorWhite)
		end
	end
end

-- ---- wormholes: black disc + halo + infalling particles (speed ∝ density) ----
-- No ring (that marks black holes). Deterministic, zero allocation.
function Draw.wormholes(level, frame)
	local whs = level.wormholeBodies
	if not whs or #whs == 0 then return end
	local t = Physics.simT
	for i = 1, #whs do
		local b = whs[i]
		local bx, by = b:positionAt(t) -- endpoints can ride rails
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer8x8)
		gfx.drawCircleAtPoint(bx, by, b.r * 2.5)
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(bx, by, b.r)
		gfx.setColor(gfx.kColorWhite)
		local rate = 0.0072 * (b.density / 2.5)
		for j = 1, 7 do
			local p = (frame * rate + j * 0.1428) % 1
			local ang = j * 2.399 + p * 6.2832
			local rad = 3 * b.r * (1 - p * p)
			gfx.drawPixel(bx + rad * cos(ang), by + rad * sin(ang))
		end
	end
end

-- ---- merge shockwave rings (preallocated; world space) ----
local RING_N <const> = 4
local RING_LIFE <const> = 0.6
local ringX = table.create(RING_N, 0)
local ringY = table.create(RING_N, 0)
local ringAge = table.create(RING_N, 0)
for i = 1, RING_N do ringAge[i] = RING_LIFE end

function Draw.addMergeRing(x, y)
	local oldest, worst = 1, -1
	for i = 1, RING_N do
		if ringAge[i] >= RING_LIFE then oldest = i break end
		if ringAge[i] > worst then oldest, worst = i, ringAge[i] end
	end
	ringX[oldest], ringY[oldest], ringAge[oldest] = x, y, 0
end

function Draw.mergeRings(dt)
	for i = 1, RING_N do
		local age = ringAge[i]
		if age < RING_LIFE then
			ringAge[i] = age + dt
			local p = age / RING_LIFE
			gfx.setColor(gfx.kColorWhite)
			gfx.setDitherPattern(p * 0.85, gfx.image.kDitherTypeBayer8x8) -- fades out
			gfx.setLineWidth(3 - 2 * p)
			gfx.drawCircleAtPoint(ringX[i], ringY[i], 12 + 240 * p)
			gfx.setLineWidth(1)
			gfx.setColor(gfx.kColorWhite)
		end
	end
end

-- ---- play-area border for scrolling levels ----
function Draw.bounds(level)
	if not level.bounds then return end
	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
	gfx.drawRect(0, 0, level.bw, level.bh)
	gfx.setColor(gfx.kColorWhite)
end

-- ---- edge arrow toward an off-screen goal wall (screen space) ----
-- Solid when fast enough to break the wall, outline when too slow.
function Draw.goalArrow(level, fastEnough, camX, camY)
	local g = level.goal
	local sx = (g.x1 + g.x2) / 2 - camX
	local sy = (g.y1 + g.y2) / 2 - camY
	if sx >= 0 and sx <= 400 and sy >= 0 and sy <= 240 then return end
	local ax = (sx < 14) and 14 or ((sx > 386) and 386 or sx)
	local ay = (sy < 14) and 14 or ((sy > 226) and 226 or sy)
	local dx, dy = sx - ax, sy - ay
	local len = sqrt(dx * dx + dy * dy)
	if len < 1 then return end
	local ux, uy = dx / len, dy / len
	local px, py = -uy, ux
	local tx, ty = ax + 7 * ux, ay + 7 * uy
	local b1x, b1y = ax - 5 * ux + 5 * px, ay - 5 * uy + 5 * py
	local b2x, b2y = ax - 5 * ux - 5 * px, ay - 5 * uy - 5 * py
	gfx.setColor(gfx.kColorWhite)
	if fastEnough then
		gfx.fillTriangle(tx, ty, b1x, b1y, b2x, b2y)
	else
		gfx.drawLine(tx, ty, b1x, b1y)
		gfx.drawLine(b1x, b1y, b2x, b2y)
		gfx.drawLine(b2x, b2y, tx, ty)
	end
end

-- ---- goal wall: dashed while too slow, solid when fast enough to break ----
function Draw.wall(level, fastEnough)
	local g = level.goal
	gfx.setColor(gfx.kColorWhite)
	if fastEnough then
		gfx.setLineWidth(4)
		gfx.drawLine(g.x1, g.y1, g.x2, g.y2)
	else
		local dx, dy = g.x2 - g.x1, g.y2 - g.y1
		local len = sqrt(dx * dx + dy * dy)
		local ux, uy = dx / len, dy / len
		gfx.setLineWidth(2)
		local d = 0
		while d < len do
			local e = d + 6
			if e > len then e = len end
			gfx.drawLine(g.x1 + ux * d, g.y1 + uy * d, g.x1 + ux * e, g.y1 + uy * e)
			d = d + 10
		end
	end
	gfx.setLineWidth(1)
end

-- ---- crash / wall-break particle burst (preallocated) ----
local P_N <const> = 8
local pX = table.create(P_N, 0)
local pY = table.create(P_N, 0)
local pVX = table.create(P_N, 0)
local pVY = table.create(P_N, 0)

function Draw.burst(x, y)
	for i = 1, P_N do
		local a = (i / P_N) * 6.2832 + 0.3
		local sp = 50 + 25 * (i % 3)
		pX[i], pY[i] = x, y
		pVX[i], pVY[i] = sp * cos(a), sp * sin(a)
	end
end

function Draw.particles(dt)
	gfx.setColor(gfx.kColorWhite)
	for i = 1, P_N do
		pX[i] = pX[i] + pVX[i] * dt
		pY[i] = pY[i] + pVY[i] * dt
		gfx.fillRect(pX[i], pY[i], 2, 2)
	end
end

-- ---- HUD: fuel bar (left), run timer (center), speed bar + vmin tick (right) ----
function Draw.hud(ship, level, speed, levelIdx, runTime)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawRect(6, 5, 82, 9)
	gfx.drawRect(312, 5, 82, 9)
	local tx = 312 + 82 * (2 / 3)
	gfx.drawLine(tx, 2, tx, 16)
	local f = ship.fuel / level.fuel
	if f > 0 then gfx.fillRect(8, 7, 78 * f, 5) end
	local smax = level.vmin * 1.5
	local sfrac = speed / smax
	if sfrac > 1 then sfrac = 1 end
	if sfrac > 0 then gfx.fillRect(314, 7, 78 * sfrac, 5) end
	gfx.drawTextAligned(string.format("%.1f", runTime or 0), 200, 3, kTextAlignment.center)
	local tag = levelIdx and ("L" .. levelIdx .. " ") or ""
	gfx.drawText(tag .. (level.name or "CUSTOM"), 6, 222)
end

-- ---- big overlay text (CRASHED / BREACH / score): bold + 2px black outline ----
local fontBold = nil
local BTN_R <const> = 11

-- width of a prompt string, counting "@A"/"@B" as a button badge
local function promptWidth(f, s)
	local w, i = 0, 1
	while i <= #s do
		if s:sub(i, i) == "@" then
			w = w + BTN_R * 2 + 3
			i = i + 2
		else
			local j = s:find("@", i, true) or (#s + 1)
			w = w + f:getTextWidth(s:sub(i, j - 1))
			i = j
		end
	end
	return w
end

-- ---- prompt line: "@A play   @B back" draws A/B as filled button badges ----
-- The disc is black-filled so the letter never fights a dithered panel or a
-- planet behind it; the white rim is what reads as "this is a button".
function Draw.prompt(text, cx, y, f)
	if not fontBold then fontBold = gfx.getSystemFont("bold") end
	f = f or fontBold
	local x = cx - promptWidth(f, text) / 2
	local h = f:getHeight()
	local i = 1
	while i <= #text do
		if text:sub(i, i) == "@" then
			local letter = text:sub(i + 1, i + 1)
			local bx, by = x + BTN_R, y + h / 2 - 1
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(bx, by, BTN_R)
			gfx.setColor(gfx.kColorWhite)
			gfx.drawCircleAtPoint(bx, by, BTN_R)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			f:drawTextAligned(letter, bx, y, kTextAlignment.center)
			x = x + BTN_R * 2 + 3
			i = i + 2
		else
			local j = text:find("@", i, true) or (#text + 1)
			local run = text:sub(i, j - 1)
			gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
			f:drawTextAligned(run, x - 1, y, kTextAlignment.left)
			f:drawTextAligned(run, x + 1, y, kTextAlignment.left)
			f:drawTextAligned(run, x, y - 1, kTextAlignment.left)
			f:drawTextAligned(run, x, y + 1, kTextAlignment.left)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			f:drawTextAligned(run, x, y, kTextAlignment.left)
			x = x + f:getTextWidth(run)
			i = j
		end
	end
end

-- ---- live name field ----
-- The system keyboard owns the right side of the screen and draws over a still
-- running game loop; it never shows the text back to you, so the field being
-- typed into has to be rendered here, in whatever room is left on the left.
-- kbLeft is the keyboard's left edge, so the panel never slides underneath it.
function Draw.nameField(text, kbLeft, frame)
	if not fontBold then fontBold = gfx.getSystemFont("bold") end
	local f = gfx.getSystemFont()
	local x, y, h = 8, 176, 54
	local w = math.max(110, math.min((kbLeft or 200) - 16, 232))
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(x, y, w, h)
	gfx.setColor(gfx.kColorWhite)
	-- the border pulses: this panel is the thing you are editing right now
	gfx.setLineWidth((math.floor(frame / 6) % 2 == 0) and 3 or 1)
	gfx.drawRect(x, y, w, h)
	gfx.setLineWidth(1)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	f:drawTextAligned("LEVEL NAME", x + 9, y + 7, kTextAlignment.left)
	-- scroll to the tail once the name outgrows the panel: the caret end is the
	-- part you are actually looking at while typing
	local shown = text or ""
	while #shown > 0 and fontBold:getTextWidth(shown) > w - 26 do
		shown = shown:sub(2)
	end
	fontBold:drawTextAligned(shown, x + 11, y + 27, kTextAlignment.left)
	if math.floor(frame / 8) % 2 == 0 then
		gfx.fillRect(x + 12 + fontBold:getTextWidth(shown), y + 27, 2, fontBold:getHeight())
	end
end

function Draw.bigText(text, cx, y)
	if not fontBold then fontBold = gfx.getSystemFont("bold") end
	gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
	for dx = -2, 2, 2 do
		for dy = -2, 2, 2 do
			if dx ~= 0 or dy ~= 0 then
				fontBold:drawTextAligned(text, cx + dx, y + dy, kTextAlignment.center)
			end
		end
	end
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	fontBold:drawTextAligned(text, cx, y, kTextAlignment.center)
end
