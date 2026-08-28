-- editor.lua — in-game level editor (developer tool + player custom levels).
--
-- Cursor mode: d-pad pans (ramping speed), A grabs the nearest handle or, over
-- empty space, opens the add palette. Grab mode: d-pad moves the object, the
-- crank adjusts the active property, A cycles properties, B commits and drops.
-- World edges: grab the right/bottom border to resize the map. Rails bodies are
-- drawn at t=0 with their path dotted; grabbing one moves the whole rail.
-- Save/play/exit live in the pause menu (main.lua swaps the items in).

local pd <const> = playdate
local gfx <const> = playdate.graphics
local sin <const> = math.sin
local cos <const> = math.cos
local sqrt <const> = math.sqrt
local atan <const> = math.atan
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local rad <const> = math.rad
local deg <const> = math.deg
local TWO_PI <const> = 2 * math.pi

Editor = {}

local ed = nil -- whole editor session state

-- ---- plain deep copy for level tables (numbers/strings/plain tables only) ----
local function deepcopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepcopy(v)
	end
	return out
end

Editor.deepcopy = deepcopy

-- authored position of a body/endpoint at t=0 (rails: on-path point)
local function posOf(obj, orbitField)
	local o = orbitField and obj[orbitField] or obj.orbit
	if o then
		local ra = o.a or o.radius
		local rb = o.b or o.radius or ra
		local th = o.phase or 0
		return o.cx + ra * cos(th), o.cy + rb * sin(th)
	end
	return obj.x or 0, obj.y or 0
end

-- Levels authored before the editor existed (L1-5) give bodies an explicit gm
-- and no density; custom levels saved by older builds can be missing fields the
-- editor edits directly. The editor works in density space, so gm is converted
-- once here and then DROPPED -- leaving it would silently outrank every density
-- edit, since loadLevelData prefers src.gm when it is present.
local function normalize(lv)
	for _, b in ipairs(lv.bodies) do
		b.r = b.r or 12
		b.density = b.density or (b.gm and b.gm / (K_DENSITY * b.r * b.r * b.r)) or 1.2
		b.gm = nil
		if b.free then b.vx, b.vy = b.vx or 0, b.vy or 0 end
	end
	for _, wh in ipairs(lv.wormholes) do
		wh.r = wh.r or 10
		wh.density = wh.density or 2.5
	end
	lv.ship.vx, lv.ship.vy = lv.ship.vx or 0, lv.ship.vy or 0
end

-- ---- session ----
function Editor.open(levelTbl, ctx)
	local lv = deepcopy(levelTbl)
	lv.bounds = lv.bounds or { w = 400, h = 240 }
	lv.bw, lv.bh = lv.bounds.w, lv.bounds.h
	lv.bodies = lv.bodies or {}
	lv.wormholes = lv.wormholes or {}
	lv.ship = lv.ship or { x = 60, y = lv.bounds.h / 2, vx = 0, vy = 0 }
	lv.goal = lv.goal or { x1 = lv.bounds.w - 40, y1 = 40, x2 = lv.bounds.w - 40, y2 = lv.bounds.h - 40 }
	lv.fuel = lv.fuel or 200
	lv.vmin = lv.vmin or 100
	normalize(lv)
	ed = {
		level = lv, ctx = ctx,
		curX = lv.ship.x, curY = lv.ship.y,
		camX = 0, camY = 0,
		grab = nil, propIdx = 1, delArmed = false,
		palette = nil, palIdx = 1,
		panHeld = 0, msg = nil, msgT = 0,
	}
end

function Editor.workingLevel()
	local lv = deepcopy(ed.level)
	lv.bounds = { w = ed.level.bounds.w, h = ed.level.bounds.h }
	lv.allBodies, lv.planetBodies, lv.freeBodies, lv.wormholeBodies = nil, nil, nil, nil
	lv.bw, lv.bh, lv.mergeEvent, lv.planetWarped = nil, nil, nil, nil
	return lv
end

function Editor.ctx()
	return ed and ed.ctx
end

function Editor.setName(name)
	ed.level.name = name
end

function Editor.name()
	return (ed and ed.level.name) or "UNTITLED"
end

function Editor.flash(msg)
	ed.msg, ed.msgT = msg, 2.0
end

-- ---- serialization: valid levels.lua entry, printed for dev copy-paste ----
local function serializeOrbit(o)
	if not o then return "nil" end
	if o.radius then
		return string.format("{ cx = %g, cy = %g, radius = %g, period = %g, phase = %g }",
			o.cx, o.cy, o.radius, o.period, o.phase or 0)
	end
	return string.format("{ cx = %g, cy = %g, a = %g, b = %g, period = %g, phase = %g }",
		o.cx, o.cy, o.a, o.b or o.a, o.period, o.phase or 0)
end

function Editor.serialize()
	local lv = ed.level
	local out = {}
	local function add(s) out[#out + 1] = s end
	add("\t{")
	add(string.format("\t\tname = %q,", lv.name or "UNTITLED"))
	add(string.format("\t\tbounds = { w = %g, h = %g },", lv.bounds.w, lv.bounds.h))
	add(string.format("\t\tship = { x = %g, y = %g, vx = %g, vy = %g, heading = 90 },",
		lv.ship.x, lv.ship.y, lv.ship.vx or 0, lv.ship.vy or 0))
	add(string.format("\t\tfuel = %g,", lv.fuel))
	add(string.format("\t\tvmin = %g,", lv.vmin))
	add("\t\tbodies = {")
	for _, b in ipairs(lv.bodies) do
		local r, d = b.r or 12, b.density or 1.2
		if b.orbit then
			add(string.format("\t\t\t{ r = %g, density = %g, orbit = %s },", r, d, serializeOrbit(b.orbit)))
		elseif b.free then
			add(string.format("\t\t\t{ x = %g, y = %g, r = %g, density = %g, free = true, vx = %g, vy = %g },",
				b.x or 0, b.y or 0, r, d, b.vx or 0, b.vy or 0))
		else
			add(string.format("\t\t\t{ x = %g, y = %g, r = %g, density = %g },", b.x or 0, b.y or 0, r, d))
		end
	end
	add("\t\t},")
	if #lv.wormholes > 0 then
		add("\t\twormholes = {")
		for _, wh in ipairs(lv.wormholes) do
			local extra = ""
			if wh.orbitA then extra = extra .. ", orbitA = " .. serializeOrbit(wh.orbitA) end
			if wh.orbitB then extra = extra .. ", orbitB = " .. serializeOrbit(wh.orbitB) end
			add(string.format("\t\t\t{ ax = %g, ay = %g, bx = %g, by = %g, r = %g, density = %g%s },",
				wh.ax or 0, wh.ay or 0, wh.bx or 0, wh.by or 0, wh.r or 10, wh.density or 2.5, extra))
		end
		add("\t\t},")
	end
	add(string.format("\t\tgoal = { x1 = %g, y1 = %g, x2 = %g, y2 = %g },",
		lv.goal.x1, lv.goal.y1, lv.goal.x2, lv.goal.y2))
	add("\t},")
	return table.concat(out, "\n")
end

-- ---- handles ----
local GRAB_R <const> = 22

local function eachHandle(cb)
	local lv = ed.level
	cb("ship", nil, lv.ship.x, lv.ship.y)
	for i, b in ipairs(lv.bodies) do
		local x, y = posOf(b)
		cb("body", i, x, y)
	end
	for i, wh in ipairs(lv.wormholes) do
		local ax, ay = posOf({ x = wh.ax, y = wh.ay, orbit = wh.orbitA })
		local bx, by = posOf({ x = wh.bx, y = wh.by, orbit = wh.orbitB })
		cb("whA", i, ax, ay)
		cb("whB", i, bx, by)
	end
	cb("wall1", nil, lv.goal.x1, lv.goal.y1)
	cb("wall2", nil, lv.goal.x2, lv.goal.y2)
end

local function nearestHandle()
	local best, bi, bx, by, bd = nil, nil, 0, 0, GRAB_R * GRAB_R
	eachHandle(function(kind, i, x, y)
		local dx, dy = x - ed.curX, y - ed.curY
		local d = dx * dx + dy * dy
		if d < bd then
			best, bi, bx, by, bd = kind, i, x, y, d
		end
	end)
	if best then return { kind = best, idx = bi } end
	-- world edges: right and bottom borders resize the map
	if math.abs(ed.curX - ed.level.bounds.w) < GRAB_R then return { kind = "edgeR" } end
	if math.abs(ed.curY - ed.level.bounds.h) < GRAB_R then return { kind = "edgeB" } end
	return nil
end

-- ---- properties ----
-- each entry: name, get() -> display string, adjust(crankDeg)
local function bodyTypeName(b)
	if b.orbit then return "RAILS" end
	if b.free then return "FREE" end
	return "STATIC"
end

local function cycleBodyType(b, dir)
	if not b.orbit and not b.free then -- static ->
		if dir >= 0 then
			local x, y = b.x, b.y
			b.orbit = { cx = x, cy = y, a = 60, b = 60, period = 5, phase = 0 }
		else
			b.free = true
			b.vx, b.vy = b.vx or 0, b.vy or 0
		end
	elseif b.orbit then -- rails ->
		local x, y = posOf(b)
		b.x, b.y = x, y
		b.orbit = nil
		if dir >= 0 then
			b.free = true
			b.vx, b.vy = b.vx or 0, b.vy or 0
		end
	else -- free ->
		b.free = nil
		if dir < 0 then
			local x, y = b.x, b.y
			b.orbit = { cx = x, cy = y, a = 60, b = 60, period = 5, phase = 0 }
		end
	end
end

local function velProps(obj, props)
	props[#props + 1] = { name = "VEL DIR", get = function()
		return string.format("%d deg", floor(deg(atan(obj.vy or 0, obj.vx or 0)) + 0.5))
	end, adjust = function(d)
		local m = sqrt((obj.vx or 0) ^ 2 + (obj.vy or 0) ^ 2)
		local a = atan(obj.vy or 0, obj.vx or 0) + rad(d)
		if m < 1 then m = (d ~= 0) and 20 or m end -- give a spin something to show
		obj.vx, obj.vy = m * cos(a), m * sin(a)
	end }
	props[#props + 1] = { name = "VEL MAG", get = function()
		return string.format("%d px/s", floor(sqrt((obj.vx or 0) ^ 2 + (obj.vy or 0) ^ 2) + 0.5))
	end, adjust = function(d)
		local m = sqrt((obj.vx or 0) ^ 2 + (obj.vy or 0) ^ 2)
		local a = atan(obj.vy or 0, obj.vx or 0)
		m = max(0, min(400, m + d * 0.5))
		obj.vx, obj.vy = m * cos(a), m * sin(a)
	end }
end

local function railProps(holder, field, props)
	local function o() return holder[field] end
	props[#props + 1] = { name = "RAIL A", get = function()
		return string.format("%d px", floor((o().a or o().radius) + 0.5))
	end, adjust = function(d)
		local ob = o()
		if ob.radius then ob.a, ob.b, ob.radius = ob.radius, ob.radius, nil end
		ob.a = max(10, min(600, ob.a + d * 0.4))
	end }
	props[#props + 1] = { name = "RAIL B", get = function()
		return string.format("%d px", floor((o().b or o().radius or o().a) + 0.5))
	end, adjust = function(d)
		local ob = o()
		if ob.radius then ob.a, ob.b, ob.radius = ob.radius, ob.radius, nil end
		ob.b = max(10, min(600, (ob.b or ob.a) + d * 0.4))
	end }
	props[#props + 1] = { name = "PERIOD", get = function()
		return string.format("%.1f s", o().period)
	end, adjust = function(d)
		local ob = o()
		local p = ob.period + d * 0.02
		if p >= -0.5 and p <= 0.5 then p = (d >= 0) and 0.5 or -0.5 end
		ob.period = max(-60, min(60, p))
	end }
	props[#props + 1] = { name = "PHASE", get = function()
		return string.format("%.2f", o().phase or 0)
	end, adjust = function(d)
		o().phase = ((o().phase or 0) + rad(d)) % TWO_PI
	end }
end

local function buildProps(grab)
	local lv = ed.level
	local props = {}
	if grab.kind == "ship" then
		velProps(lv.ship, props)
		props[#props + 1] = { name = "FUEL", get = function()
			return string.format("%d", floor(lv.fuel + 0.5))
		end, adjust = function(d) lv.fuel = max(20, min(600, lv.fuel + d * 0.5)) end }
	elseif grab.kind == "wall1" or grab.kind == "wall2" then
		props[#props + 1] = { name = "VMIN", get = function()
			return string.format("%d px/s", floor(lv.vmin + 0.5))
		end, adjust = function(d) lv.vmin = max(30, min(400, lv.vmin + d * 0.4)) end }
	elseif grab.kind == "body" then
		local b = lv.bodies[grab.idx]
		props[#props + 1] = { name = "RADIUS", get = function()
			return string.format("%d px", floor(b.r + 0.5))
		end, adjust = function(d) b.r = max(4, min(60, b.r + d * 0.1)) end }
		props[#props + 1] = { name = "DENSITY", get = function()
			return string.format("%.2f", b.density)
		end, adjust = function(d) b.density = max(0.3, min(12, b.density + d * 0.01)) end }
		props[#props + 1] = { name = "TYPE", get = function()
			return bodyTypeName(b)
		end, adjust = function(d)
			ed.typeAcc = (ed.typeAcc or 0) + d
			if ed.typeAcc > 45 then cycleBodyType(b, 1) ed.typeAcc = 0 end
			if ed.typeAcc < -45 then cycleBodyType(b, -1) ed.typeAcc = 0 end
			ed.props = buildProps(grab) -- prop list changes with the type
		end }
		if b.orbit then railProps(b, "orbit", props) end
		if b.free then velProps(b, props) end
		props[#props + 1] = { name = "DELETE", get = function()
			return ed.delArmed and "ARMED - press A" or "crank to arm"
		end, adjust = function(d)
			ed.delAcc = (ed.delAcc or 0) + d
			if math.abs(ed.delAcc) > 90 then ed.delArmed = true end
		end, isDelete = true }
	elseif grab.kind == "whA" or grab.kind == "whB" then
		local wh = lv.wormholes[grab.idx]
		local orbField = (grab.kind == "whA") and "orbitA" or "orbitB"
		props[#props + 1] = { name = "RADIUS", get = function()
			return string.format("%d px", floor(wh.r + 0.5))
		end, adjust = function(d) wh.r = max(6, min(24, wh.r + d * 0.1)) end }
		props[#props + 1] = { name = "DENSITY", get = function()
			return string.format("%.2f", wh.density)
		end, adjust = function(d) wh.density = max(0.3, min(8, wh.density + d * 0.01)) end }
		props[#props + 1] = { name = "TYPE", get = function()
			return wh[orbField] and "RAILED MOUTH" or "FIXED MOUTH"
		end, adjust = function(d)
			ed.typeAcc = (ed.typeAcc or 0) + d
			if math.abs(ed.typeAcc) > 45 then
				ed.typeAcc = 0
				if wh[orbField] then
					local hx, hy = posOf({ orbit = wh[orbField] })
					if grab.kind == "whA" then wh.ax, wh.ay = hx, hy else wh.bx, wh.by = hx, hy end
					wh[orbField] = nil
				else
					local hx = (grab.kind == "whA") and wh.ax or wh.bx
					local hy = (grab.kind == "whA") and wh.ay or wh.by
					wh[orbField] = { cx = hx, cy = hy, a = 50, b = 50, period = 6, phase = 0 }
				end
				ed.props = buildProps(grab)
			end
		end }
		if wh[orbField] then railProps(wh, orbField, props) end
		props[#props + 1] = { name = "DELETE PAIR", get = function()
			return ed.delArmed and "ARMED - press A" or "crank to arm"
		end, adjust = function(d)
			ed.delAcc = (ed.delAcc or 0) + d
			if math.abs(ed.delAcc) > 90 then ed.delArmed = true end
		end, isDelete = true }
	elseif grab.kind == "edgeR" then
		props[#props + 1] = { name = "WORLD W", get = function()
			return string.format("%d", lv.bounds.w)
		end, adjust = function(d) lv.bounds.w = max(400, min(2400, lv.bounds.w + d)) end }
	elseif grab.kind == "edgeB" then
		props[#props + 1] = { name = "WORLD H", get = function()
			return string.format("%d", lv.bounds.h)
		end, adjust = function(d) lv.bounds.h = max(240, min(1440, lv.bounds.h + d)) end }
	end
	return props
end

-- move whatever is grabbed by (dx, dy)
local function moveGrab(dx, dy)
	local lv = ed.level
	local g = ed.grab
	if g.kind == "ship" then
		lv.ship.x, lv.ship.y = lv.ship.x + dx, lv.ship.y + dy
	elseif g.kind == "body" then
		local b = lv.bodies[g.idx]
		if b.orbit then
			b.orbit.cx, b.orbit.cy = b.orbit.cx + dx, b.orbit.cy + dy
		else
			b.x, b.y = b.x + dx, b.y + dy
		end
	elseif g.kind == "whA" then
		local wh = lv.wormholes[g.idx]
		if wh.orbitA then wh.orbitA.cx, wh.orbitA.cy = wh.orbitA.cx + dx, wh.orbitA.cy + dy
		else wh.ax, wh.ay = wh.ax + dx, wh.ay + dy end
	elseif g.kind == "whB" then
		local wh = lv.wormholes[g.idx]
		if wh.orbitB then wh.orbitB.cx, wh.orbitB.cy = wh.orbitB.cx + dx, wh.orbitB.cy + dy
		else wh.bx, wh.by = wh.bx + dx, wh.by + dy end
	elseif g.kind == "wall1" then
		lv.goal.x1, lv.goal.y1 = lv.goal.x1 + dx, lv.goal.y1 + dy
	elseif g.kind == "wall2" then
		lv.goal.x2, lv.goal.y2 = lv.goal.x2 + dx, lv.goal.y2 + dy
	end
end

local function grabPos()
	local g = ed.grab
	local lv = ed.level
	if g.kind == "ship" then return lv.ship.x, lv.ship.y end
	if g.kind == "body" then return posOf(lv.bodies[g.idx]) end
	if g.kind == "whA" then
		local wh = lv.wormholes[g.idx]
		return posOf({ x = wh.ax, y = wh.ay, orbit = wh.orbitA })
	end
	if g.kind == "whB" then
		local wh = lv.wormholes[g.idx]
		return posOf({ x = wh.bx, y = wh.by, orbit = wh.orbitB })
	end
	if g.kind == "wall1" then return lv.goal.x1, lv.goal.y1 end
	if g.kind == "wall2" then return lv.goal.x2, lv.goal.y2 end
	if g.kind == "edgeR" then return lv.bounds.w, ed.curY end
	if g.kind == "edgeB" then return ed.curX, lv.bounds.h end
end

local function deleteGrab()
	local lv = ed.level
	local g = ed.grab
	if g.kind == "body" then
		table.remove(lv.bodies, g.idx)
	elseif g.kind == "whA" or g.kind == "whB" then
		table.remove(lv.wormholes, g.idx)
	end
	ed.grab = nil
	ed.delArmed = false
	Editor.flash("DELETED")
end

-- ---- add palette ----
local PALETTE <const> = { "STATIC PLANET", "RAILS PLANET", "FREE PLANET", "WORMHOLE PAIR", "RAILED WORMHOLE" }

local function spawnFromPalette(idx)
	local lv = ed.level
	local x, y = ed.curX, ed.curY
	if idx == 1 then
		lv.bodies[#lv.bodies + 1] = { x = x, y = y, r = 12, density = 1.2 }
		ed.grab = { kind = "body", idx = #lv.bodies }
	elseif idx == 2 then
		lv.bodies[#lv.bodies + 1] = { r = 8, density = 1.5,
			orbit = { cx = x, cy = y, a = 60, b = 60, period = 5, phase = 0 } }
		ed.grab = { kind = "body", idx = #lv.bodies }
	elseif idx == 3 then
		lv.bodies[#lv.bodies + 1] = { x = x, y = y, r = 10, density = 1.4, free = true, vx = 0, vy = 20 }
		ed.grab = { kind = "body", idx = #lv.bodies }
	elseif idx == 4 then
		lv.wormholes[#lv.wormholes + 1] = { ax = x, ay = y, bx = x + 120, by = y, r = 10, density = 2.5 }
		ed.grab = { kind = "whA", idx = #lv.wormholes }
	else
		lv.wormholes[#lv.wormholes + 1] = { ax = x, ay = y, bx = x + 120, by = y, r = 10, density = 2.5,
			orbitA = { cx = x, cy = y, a = 50, b = 50, period = 6, phase = 0 } }
		ed.grab = { kind = "whA", idx = #lv.wormholes }
	end
	ed.props = buildProps(ed.grab)
	ed.propIdx = 1
	ed.delArmed = false
	ed.delAcc = 0
end

-- ---- update ----
local function panSpeed()
	ed.panHeld = ed.panHeld + 1
	return min(18, 6 + ed.panHeld * 0.4)
end

function Editor.update()
	if pd.keyboard and pd.keyboard.isVisible and pd.keyboard.isVisible() then
		ed.kbFrame = (ed.kbFrame or 0) + 1
		Editor.draw()
		return
	end
	ed.kbFrame = 0
	local crank = pd.getCrankChange()

	if ed.palette then
		if pd.buttonJustPressed(pd.kButtonUp) or pd.buttonJustPressed(pd.kButtonLeft) then
			ed.palIdx = ((ed.palIdx - 2) % #PALETTE) + 1
		elseif pd.buttonJustPressed(pd.kButtonDown) or pd.buttonJustPressed(pd.kButtonRight) then
			ed.palIdx = (ed.palIdx % #PALETTE) + 1
		end
		if pd.buttonJustPressed(pd.kButtonA) then
			spawnFromPalette(ed.palIdx)
			ed.palette = nil
			Sound.select()
		elseif pd.buttonJustPressed(pd.kButtonB) then
			ed.palette = nil
		end
		Editor.draw()
		return
	end

	local anyDir = pd.buttonIsPressed(pd.kButtonLeft) or pd.buttonIsPressed(pd.kButtonRight)
		or pd.buttonIsPressed(pd.kButtonUp) or pd.buttonIsPressed(pd.kButtonDown)
	if not anyDir then ed.panHeld = 0 end

	if ed.grab then
		local sp = anyDir and panSpeed() or 0
		local dx, dy = 0, 0
		if pd.buttonIsPressed(pd.kButtonLeft) then dx = dx - sp end
		if pd.buttonIsPressed(pd.kButtonRight) then dx = dx + sp end
		if pd.buttonIsPressed(pd.kButtonUp) then dy = dy - sp end
		if pd.buttonIsPressed(pd.kButtonDown) then dy = dy + sp end
		if dx ~= 0 or dy ~= 0 then moveGrab(dx * 0.5, dy * 0.5) end
		local prop = ed.props[ed.propIdx]
		if prop and crank ~= 0 then prop.adjust(crank) end
		if pd.buttonJustPressed(pd.kButtonA) then
			local p = ed.props[ed.propIdx]
			if p and p.isDelete and ed.delArmed then
				deleteGrab()
			else
				ed.propIdx = (ed.propIdx % #ed.props) + 1
				ed.delArmed = false
				ed.delAcc = 0
				Sound.hover()
			end
		elseif pd.buttonJustPressed(pd.kButtonB) then
			ed.grab = nil
			Sound.select()
		end
		if ed.grab then
			ed.curX, ed.curY = grabPos()
		end
	else
		local sp = anyDir and panSpeed() or 0
		if pd.buttonIsPressed(pd.kButtonLeft) then ed.curX = ed.curX - sp end
		if pd.buttonIsPressed(pd.kButtonRight) then ed.curX = ed.curX + sp end
		if pd.buttonIsPressed(pd.kButtonUp) then ed.curY = ed.curY - sp end
		if pd.buttonIsPressed(pd.kButtonDown) then ed.curY = ed.curY + sp end
		ed.curX = max(-40, min(ed.level.bounds.w + 40, ed.curX))
		ed.curY = max(-40, min(ed.level.bounds.h + 40, ed.curY))
		if pd.buttonJustPressed(pd.kButtonA) then
			local h = nearestHandle()
			if h then
				ed.grab = h
				ed.props = buildProps(h)
				ed.propIdx = 1
				ed.delArmed = false
				ed.delAcc = 0
				Sound.select()
			else
				ed.palette = true
				ed.palIdx = 1
				Sound.hover()
			end
		end
	end

	-- camera chases the cursor
	local tx = max(0, min(ed.level.bounds.w - 400, ed.curX - 200))
	local ty = max(0, min(max(0, ed.level.bounds.h - 240), ed.curY - 120))
	ed.camX = ed.camX + (tx - ed.camX) * 0.3
	ed.camY = ed.camY + (ty - ed.camY) * 0.3

	if ed.msgT > 0 then ed.msgT = ed.msgT - 1 / 30 end
	Editor.draw()
end

-- ---- drawing ----
local function drawRailPath(o)
	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.6, gfx.image.kDitherTypeBayer8x8)
	local ra = o.a or o.radius
	local rb = o.b or o.radius or ra
	for k = 0, 23 do
		local th = k * TWO_PI / 24
		gfx.drawPixel(o.cx + ra * cos(th), o.cy + rb * sin(th))
	end
	gfx.setColor(gfx.kColorWhite)
end

local function drawArrow(x, y, vx, vy)
	local m = sqrt(vx * vx + vy * vy)
	if m < 1 then return end
	local s = min(40, 10 + m * 0.15)
	local ux, uy = vx / m, vy / m
	local tx, ty = x + ux * s, y + uy * s
	gfx.drawLine(x, y, tx, ty)
	gfx.drawLine(tx, ty, tx - ux * 5 - uy * 3, ty - uy * 5 + ux * 3)
	gfx.drawLine(tx, ty, tx - ux * 5 + uy * 3, ty - uy * 5 - ux * 3)
end

function Editor.draw()
	local lv = ed.level
	gfx.clear(gfx.kColorBlack)
	gfx.setDrawOffset(-ed.camX, -ed.camY)

	gfx.setColor(gfx.kColorWhite)
	gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
	gfx.drawRect(0, 0, lv.bounds.w, lv.bounds.h)
	gfx.setColor(gfx.kColorWhite)

	-- goal wall
	gfx.setLineWidth(2)
	gfx.drawLine(lv.goal.x1, lv.goal.y1, lv.goal.x2, lv.goal.y2)
	gfx.setLineWidth(1)
	gfx.drawRect(lv.goal.x1 - 3, lv.goal.y1 - 3, 6, 6)
	gfx.drawRect(lv.goal.x2 - 3, lv.goal.y2 - 3, 6, 6)

	-- bodies
	for _, b in ipairs(lv.bodies) do
		local x, y = posOf(b)
		if b.orbit then drawRailPath(b.orbit) end
		local d = b.density or 1
		if d >= D_BLACKHOLE then
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(x, y, b.r)
			gfx.setColor(gfx.kColorWhite)
			gfx.drawCircleAtPoint(x, y, b.r)
		elseif d <= D_SOLID then
			gfx.fillCircleAtPoint(x, y, b.r)
		else
			gfx.setDitherPattern(0.45, gfx.image.kDitherTypeBayer8x8)
			gfx.fillCircleAtPoint(x, y, b.r)
			gfx.setColor(gfx.kColorWhite)
		end
		if b.free then drawArrow(x, y, b.vx or 0, b.vy or 0) end
	end

	-- wormholes
	for _, wh in ipairs(lv.wormholes) do
		local ax, ay = posOf({ x = wh.ax, y = wh.ay, orbit = wh.orbitA })
		local bx, by = posOf({ x = wh.bx, y = wh.by, orbit = wh.orbitB })
		if wh.orbitA then drawRailPath(wh.orbitA) end
		if wh.orbitB then drawRailPath(wh.orbitB) end
		gfx.setColor(gfx.kColorBlack)
		gfx.fillCircleAtPoint(ax, ay, wh.r)
		gfx.fillCircleAtPoint(bx, by, wh.r)
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.4, gfx.image.kDitherTypeBayer8x8)
		gfx.drawCircleAtPoint(ax, ay, wh.r)
		gfx.drawCircleAtPoint(bx, by, wh.r)
		gfx.setColor(gfx.kColorWhite)
		gfx.setDitherPattern(0.6, gfx.image.kDitherTypeBayer8x8)
		gfx.drawLine(ax, ay, bx, by)
		gfx.setColor(gfx.kColorWhite)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		gfx.drawTextAligned("A", ax, ay - 8, kTextAlignment.center)
		gfx.drawTextAligned("B", bx, by - 8, kTextAlignment.center)
	end

	-- ship
	local sx, sy = lv.ship.x, lv.ship.y
	gfx.fillTriangle(sx, sy - 8, sx - 6, sy + 6, sx + 6, sy + 6)
	drawArrow(sx, sy, lv.ship.vx or 0, lv.ship.vy or 0)

	-- cursor
	local hx = ed.grab and { grabPos() } or nil
	gfx.drawLine(ed.curX - 8, ed.curY, ed.curX + 8, ed.curY)
	gfx.drawLine(ed.curX, ed.curY - 8, ed.curX, ed.curY + 8)
	if not ed.grab then
		local h = nearestHandle()
		if h and h.kind ~= "edgeR" and h.kind ~= "edgeB" then
			ed.grab = h -- borrow grabPos for the highlight, then release
			local gx, gy = grabPos()
			ed.grab = nil
			gfx.setLineWidth(2)
			gfx.drawCircleAtPoint(gx, gy, 14)
			gfx.setLineWidth(1)
		end
	end

	gfx.setDrawOffset(0, 0)

	-- HUD
	local typing = pd.keyboard and pd.keyboard.isVisible and pd.keyboard.isVisible()
	-- while the keyboard is up the header follows the keystrokes, not the saved
	-- name: nothing is committed to lv.name until the keyboard is dismissed with OK
	local name = typing and (pd.keyboard.text or "") or (lv.name or "UNTITLED")
	Draw.bigText("EDIT: " .. name, 200, 2)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawTextAligned(string.format("world %dx%d  fuel %d  vmin %d",
		lv.bounds.w, lv.bounds.h, floor(lv.fuel), floor(lv.vmin)), 200, 24, kTextAlignment.center)

	if ed.palette then
		local x, y = 130, 60
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(x, y, 140, 20 + #PALETTE * 18)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawRect(x, y, 140, 20 + #PALETTE * 18)
		gfx.drawTextAligned("ADD", 200, y + 2, kTextAlignment.center)
		for i, label in ipairs(PALETTE) do
			local ly = y + 18 + (i - 1) * 18
			if i == ed.palIdx then
				gfx.fillRect(x + 2, ly, 136, 17)
				gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
			end
			gfx.drawTextAligned(label, 200, ly + 1, kTextAlignment.center)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		end
		Draw.prompt("@A add   @B cancel", 200, 218, gfx.getSystemFont())
	elseif ed.grab then
		local p = ed.props[ed.propIdx]
		local label = ed.grab.kind:upper()
		if p then
			label = label .. "  |  " .. p.name .. ": " .. p.get()
		end
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 196, 400, 44)
		gfx.setColor(gfx.kColorWhite)
		gfx.drawTextAligned(label, 200, 198, kTextAlignment.center)
		Draw.prompt("dpad move  crank adjust  @A next  @B drop", 200, 216, gfx.getSystemFont())
	else
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRect(0, 214, 400, 26)
		gfx.setColor(gfx.kColorWhite)
		Draw.prompt("@A grab/add   menu: save-play-exit", 200, 216, gfx.getSystemFont())
	end

	if ed.msgT and ed.msgT > 0 and ed.msg then
		Draw.bigText(ed.msg, 200, 100)
	end

	if typing then
		local kbLeft = pd.keyboard.left and pd.keyboard.left() or 200
		Draw.nameField(pd.keyboard.text, kbLeft, ed.kbFrame or 0)
	end
end
