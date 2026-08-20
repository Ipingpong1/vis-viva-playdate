-- physics.lua — leapfrog (KDK velocity-Verlet) integrator, gravity field, event checks.
-- Ship is a massless test particle. Planet positions are read ONLY through
-- body:positionAt(t), so moving (on-rails) planets need no integrator changes.

local sqrt <const> = math.sqrt
local max <const> = math.max
local sin <const> = math.sin
local cos <const> = math.cos
local TWO_PI <const> = 2 * math.pi

Physics = { simT = 0 }

local BodyIndex = {
	-- static bodies and free bodies report their own x,y (free bodies are
	-- integrated, so x,y is live state); railed bodies ride a parametric
	-- ellipse: orbit = {cx, cy, a, b, period, phase} (radius = circular shorthand)
	positionAt = function(b, t)
		local o = b.orbit
		if not o then return b.x, b.y end
		local th = TWO_PI * (t / o.period) + (o.phase or 0)
		local ra = o.a or o.radius
		local rb = o.b or o.radius or ra
		return o.cx + ra * cos(th), o.cy + rb * sin(th)
	end,
}
local bodyMeta = { __index = BodyIndex }

function Physics.attach(bodies)
	for i = 1, #bodies do
		setmetatable(bodies[i], bodyMeta)
	end
end

function Physics.gravity(px, py, t, bodies)
	local ax, ay = 0, 0
	for i = 1, #bodies do
		local b = bodies[i]
		local bx, by = b:positionAt(t)
		local dx, dy = bx - px, by - py
		local d2 = dx * dx + dy * dy
		if d2 < 4 then d2 = 4 end -- NaN insurance; unreachable (crash radius >= 8)
		local s = b.gm / (d2 * sqrt(d2))
		ax = ax + dx * s
		ay = ay + dy * s
	end
	return ax, ay
end

-- Wall crossing (segment-segment on the substep displacement), body hit
-- (planet crash or wormhole teleport), bounds. Returns "win", impactSpeed |
-- "crash" | nil. May reflect (slow wall hit) or teleport (wormhole) the ship.
-- Order matters: the wall check runs FIRST on the pre-teleport displacement,
-- so a warp can never register as a wall crossing.
local function checkEvents(x0, y0, ship, level)
	local g = level.goal
	local x1, y1 = ship.x, ship.y
	local vx, vy = ship.vx, ship.vy

	local rx, ry = x1 - x0, y1 - y0
	local sx, sy = g.x2 - g.x1, g.y2 - g.y1
	local denom = rx * sy - ry * sx
	if denom ~= 0 then
		local qpx, qpy = g.x1 - x0, g.y1 - y0
		local t = (qpx * sy - qpy * sx) / denom -- along motion
		local u = (qpx * ry - qpy * rx) / denom -- along wall
		if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
			local speed = sqrt(vx * vx + vy * vy)
			-- gateTimer keeps the gate open a beat after vmin is reached, so a
			-- hair of drag on the approach cannot slam it shut mid-run
			if speed >= level.vmin or ship.gateTimer > 0 then
				return "win", speed
			end
			-- too slow: reflect about wall normal, keep tangential component
			local len = sqrt(sx * sx + sy * sy)
			local nx, ny = -sy / len, sx / len
			local vdn = vx * nx + vy * ny
			ship.vx = vx - (1 + RESTITUTION) * vdn * nx
			ship.vy = vy - (1 + RESTITUTION) * vdn * ny
			-- park just off the wall on the incoming side (prevents sticking)
			local hx, hy = x0 + t * rx, y0 + t * ry
			local side = (vdn > 0) and -1 or 1
			ship.x, ship.y = hx + side * 0.75 * nx, hy + side * 0.75 * ny
			ship.bounced = true
			ship.bounceSpeed = speed
		end
	end

	local bodies = level.allBodies
	local st = Physics.simT
	for i = 1, #bodies do
		local b = bodies[i]
		local bx, by = b:positionAt(st)
		local dx, dy = ship.x - bx, ship.y - by
		if dx * dx + dy * dy < b.r * b.r then
			if b.wormhole then
				-- re-entering the hole you just exited, too soon: trapped -> dead
				if ship.exitTimer > 0 and b.id == ship.exitHoleId then
					return "crash"
				end
				local tw = b.twin
				local twx, twy = tw:positionAt(st) -- twins can ride rails too
				local svx, svy = ship.vx, ship.vy
				local sp = sqrt(svx * svx + svy * svy)
				local ux, uy
				if sp >= 0.5 then
					ux, uy = svx / sp, svy / sp
				else
					-- degenerate: exit away from the twin, along twin->entry axis
					local fx, fy = bx - twx, by - twy
					local fl = sqrt(fx * fx + fy * fy)
					ux, uy = fx / fl, fy / fl
				end
				ship.x, ship.y = twx + ux * (tw.r + 3), twy + uy * (tw.r + 3)
				ship.exitHoleId = tw.id
				ship.exitTimer = TRAP_WINDOW
				ship.warped = true
				-- no return: remaining bodies + bounds run against the NEW
				-- position, so a bad exit self-punishes next check/substep
			else
				return "crash"
			end
		end
	end

	local x, y = ship.x, ship.y
	if x < -60 or x > level.bw + 60 or y < -60 or y > level.bh + 60 then
		return "crash"
	end
	return nil
end

-- ---- free-body (simulated planet) machinery ----

-- gravity on a planet from every body except itself
local function planetAccel(fb, bodies, t)
	local ax, ay = 0, 0
	for i = 1, #bodies do
		local b = bodies[i]
		if b ~= fb then
			local bx, by = b:positionAt(t)
			local dx, dy = bx - fb.x, by - fb.y
			local d2 = dx * dx + dy * dy
			if d2 < 4 then d2 = 4 end
			local s = b.gm / (d2 * sqrt(d2))
			ax = ax + dx * s
			ay = ay + dy * s
		end
	end
	return ax, ay
end

local function removeBody(level, b)
	local function rm(list)
		for i = #list, 1, -1 do
			if list[i] == b then table.remove(list, i) end
		end
	end
	rm(level.allBodies)
	rm(level.planetBodies)
	rm(level.freeBodies)
end

-- static(2) > rails(1) > free(0): merges keep the most-constrained motion
local function rankOf(b)
	if b.free then return 0 end
	if b.orbit then return 1 end
	return 2
end

-- winner absorbs loser: mass sums, volume sums (r = cbrt(r1^3+r2^3)); a
-- free-free merge also conserves momentum and mass-weights the position
local function mergePlanets(level, t, a, b)
	if rankOf(b) > rankOf(a) or (rankOf(b) == rankOf(a) and b.gm > a.gm) then
		a, b = b, a
	end
	local ax0, ay0 = a:positionAt(t)
	local bx0, by0 = b:positionAt(t)
	local m1, m2 = a.gm, b.gm
	if a.free and b.free then
		a.x = (ax0 * m1 + bx0 * m2) / (m1 + m2)
		a.y = (ay0 * m1 + by0 * m2) / (m1 + m2)
		a.vx = (a.vx * m1 + b.vx * m2) / (m1 + m2)
		a.vy = (a.vy * m1 + b.vy * m2) / (m1 + m2)
	end
	a.gm = m1 + m2
	a.r = (a.r ^ 3 + b.r ^ 3) ^ (1 / 3)
	a.density = a.gm / (K_DENSITY * a.r ^ 3)
	removeBody(level, b)
	level.mergeEvent = { x = (ax0 + bx0) / 2, y = (ay0 + by0) / 2 }
end

-- planet-vs-wormhole capture (planets warp too, velocity preserved) and
-- planet-vs-planet merges. Only pairs involving a free body can collide.
local function resolvePlanetCollisions(level, t)
	local frees = level.freeBodies
	local i = 1
	while i <= #frees do
		local fb = frees[i]
		local gone = false
		local whs = level.wormholeBodies
		for w = 1, #whs do
			local wb = whs[w]
			local wbx, wby = wb:positionAt(t)
			local dx, dy = fb.x - wbx, fb.y - wby
			if dx * dx + dy * dy < wb.r * wb.r then
				if not (fb.exitTimer > 0 and fb.exitHoleId == wb.id) then
					local tw = wb.twin
					local twx, twy = tw:positionAt(t)
					local sp = sqrt(fb.vx * fb.vx + fb.vy * fb.vy)
					local ux, uy
					if sp >= 0.5 then
						ux, uy = fb.vx / sp, fb.vy / sp
					else
						local fx, fy = wbx - twx, wby - twy
						local fl = sqrt(fx * fx + fy * fy)
						ux, uy = fx / fl, fy / fl
					end
					fb.x = twx + ux * (tw.r + fb.r + 3)
					fb.y = twy + uy * (tw.r + fb.r + 3)
					fb.exitHoleId = tw.id
					fb.exitTimer = TRAP_WINDOW -- cooldown only: planets never trap-crash
					level.planetWarped = true
				end
				break
			end
		end
		local planets = level.planetBodies
		for p = 1, #planets do
			local pb = planets[p]
			if pb ~= fb then
				local px, py = pb:positionAt(t)
				local dx, dy = fb.x - px, fb.y - py
				local rr = fb.r + pb.r
				if dx * dx + dy * dy < rr * rr then
					gone = (rankOf(pb) > rankOf(fb)) or (rankOf(pb) == rankOf(fb) and pb.gm >= fb.gm)
					mergePlanets(level, t, fb, pb)
					break
				end
			end
		end
		if not gone then i = i + 1 end
	end
end

-- One display frame = NSUB leapfrog substeps of length H. Thrust folded into both
-- kicks (constant within the frame); pure symplectic leapfrog while coasting.
function Physics.frame(ship, level, thrusting)
	local bodies = level.allBodies
	for _ = 1, NSUB do
		if ship.exitTimer > 0 then
			ship.exitTimer = max(0, ship.exitTimer - H)
		end
		local tax, tay = 0, 0
		if thrusting and ship.fuel > 0 then
			tax, tay = THRUST * ship.hx, THRUST * ship.hy
			ship.fuel = max(0, ship.fuel - THRUST * H) -- fuel IS delta-v (px/s)
		end
		local t = Physics.simT
		-- free planets integrate first (same KDK), then collide/merge/warp
		local frees = level.freeBodies
		if frees and #frees > 0 then
			for i = 1, #frees do
				local fb = frees[i]
				if fb.exitTimer > 0 then fb.exitTimer = max(0, fb.exitTimer - H) end
				local fax, fay = planetAccel(fb, bodies, t)
				fb.vx = fb.vx + 0.5 * H * fax
				fb.vy = fb.vy + 0.5 * H * fay
				fb.x = fb.x + H * fb.vx
				fb.y = fb.y + H * fb.vy
			end
			resolvePlanetCollisions(level, t + H)
			for i = 1, #frees do
				local fb = frees[i]
				local fax, fay = planetAccel(fb, bodies, t + H)
				fb.vx = fb.vx + 0.5 * H * fax
				fb.vy = fb.vy + 0.5 * H * fay
			end
		end
		local gx, gy = Physics.gravity(ship.x, ship.y, t, bodies)
		ship.vx = ship.vx + 0.5 * H * (gx + tax)
		ship.vy = ship.vy + 0.5 * H * (gy + tay)
		local x0, y0 = ship.x, ship.y
		ship.x = ship.x + H * ship.vx
		ship.y = ship.y + H * ship.vy
		Physics.simT = t + H
		local vmin = level.vmin
		if ship.vx * ship.vx + ship.vy * ship.vy >= vmin * vmin then
			ship.gateTimer = GATE_LATCH
		elseif ship.gateTimer > 0 then
			ship.gateTimer = max(0, ship.gateTimer - H)
		end
		local ev, speed = checkEvents(x0, y0, ship, level)
		if ev then return ev, speed end
		gx, gy = Physics.gravity(ship.x, ship.y, Physics.simT, bodies)
		ship.vx = ship.vx + 0.5 * H * (gx + tax)
		ship.vy = ship.vy + 0.5 * H * (gy + tay)
	end
	return nil
end

-- Specific orbital energy (debug): bounded oscillation during coast = healthy leapfrog.
function Physics.energy(ship, level)
	local bodies = level.allBodies
	local e = 0.5 * (ship.vx * ship.vx + ship.vy * ship.vy)
	local st = Physics.simT
	for i = 1, #bodies do
		local b = bodies[i]
		local bx, by = b:positionAt(st)
		local dx, dy = ship.x - bx, ship.y - by
		e = e - b.gm / sqrt(dx * dx + dy * dy)
	end
	return e
end
