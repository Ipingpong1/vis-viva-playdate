-- levels.lua — pure data. This table shape is the future proc-gen target.
-- ship: spawn state (vx,vy nonzero = start already in motion; heading in degrees, 0=up CW)
-- fuel: delta-v budget in px/s. vmin: wall break speed in px/s.
-- bodies: either explicit gm (px^3/s^2) or { r=, density= } (gm = K_DENSITY*density*r^3
--         derived at load). density drives the fill: <=1.8 solid white, darker dither
--         as it rises, >=6 = black hole (black disc + white ring). orbit=nil is static;
--         orbit = { cx=, cy=, radius=, period=, phase= } puts a body on rails.
-- bounds: { w=, h= } world size; absent = 400x240 with a locked camera.
-- wormholes: { {ax,ay, bx,by, r, density}, ... } — linked pairs. Both endpoints pull
--         (gm from density) and teleport preserving velocity; re-entering the hole you
--         just exited within TRAP_WINDOW crashes.
-- goal: wall segment; crossing at speed >= vmin wins, slower reflects.

Levels = {
	{
		name = "STRAIGHT SHOT",
		ship = { x = 50, y = 120, vx = 0, vy = 0, heading = 90 },
		fuel = 250,
		vmin = 90,
		bodies = {
			{ x = 200, y = 178, gm = 240000, r = 13, orbit = nil },
		},
		goal = { x1 = 372, y1 = 60, x2 = 372, y2 = 180 },
	},
	{
		name = "ORBIT INSERTION",
		-- starts in a circular clockwise orbit at r=70 (v = sqrt(gm/70) ~ 69.7)
		ship = { x = 200, y = 50, vx = 69.7, vy = 0, heading = 90 },
		fuel = 150,
		vmin = 110,
		bodies = {
			{ x = 200, y = 120, gm = 340000, r = 14, orbit = nil },
		},
		goal = { x1 = 372, y1 = 90, x2 = 372, y2 = 150 },
	},
	{
		name = "POWER DIVE",
		-- fuel alone can't reach vmin by burning straight at the wall — dive past
		-- the planet and burn at periapsis (Oberth effect) to break it.
		ship = { x = 60, y = 120, vx = 0, vy = 0, heading = 90 },
		fuel = 120,
		vmin = 150,
		bodies = {
			{ x = 260, y = 120, gm = 450000, r = 16, orbit = nil },
		},
		goal = { x1 = 160, y1 = 216, x2 = 330, y2 = 216 },
	},
	{
		name = "BINARY",
		ship = { x = 40, y = 210, vx = 0, vy = 0, heading = 45 },
		fuel = 200,
		vmin = 120,
		bodies = {
			{ x = 150, y = 90, gm = 220000, r = 12, orbit = nil },
			{ x = 250, y = 150, gm = 220000, r = 12, orbit = nil },
		},
		goal = { x1 = 372, y1 = 40, x2 = 372, y2 = 110 },
	},
	{
		name = "MOON SHOT",
		-- post-MVP: give the moon orbit = {cx=170, cy=120, radius=130, period=8, phase=0}
		ship = { x = 40, y = 40, vx = 0, vy = 0, heading = 135 },
		fuel = 220,
		vmin = 140,
		bodies = {
			{ x = 170, y = 120, gm = 380000, r = 16, orbit = nil },
			{ x = 300, y = 120, gm = 80000, r = 8, orbit = nil },
		},
		goal = { x1 = 372, y1 = 70, x2 = 372, y2 = 170 },
	},

	-- ============ SET 2 (6-10): density & black holes, scrolling camera ============
	{
		name = "HEAVYWEIGHT",
		-- same density, different size: the giant pulls 15x harder than the pebble
		bounds = { w = 600, h = 360 },
		ship = { x = 60, y = 300, vx = 0, vy = 0, heading = 60 },
		fuel = 260,
		vmin = 100,
		bodies = {
			{ x = 160, y = 120, r = 8, density = 1.2 },
			{ x = 380, y = 180, r = 20, density = 1.2 },
		},
		goal = { x1 = 540, y1 = 60, x2 = 540, y2 = 180 },
	},
	{
		name = "LEAD LINING",
		-- same size, different density: the dark twin pulls 3.75x harder than it looks
		bounds = { w = 600, h = 360 },
		ship = { x = 60, y = 180, vx = 0, vy = 0, heading = 90 },
		fuel = 220,
		vmin = 110,
		bodies = {
			{ x = 220, y = 120, r = 12, density = 1.2 },
			{ x = 380, y = 240, r = 12, density = 4.5 },
		},
		goal = { x1 = 540, y1 = 120, x2 = 540, y2 = 240 },
	},
	{
		name = "EVENT HORIZON",
		-- first black hole; fuel < vmin: only an Oberth dive past the hole works,
		-- and the wall sits where the post-periapsis sling naturally exits
		bounds = { w = 800, h = 480 },
		ship = { x = 140, y = 240, vx = 0, vy = 0, heading = 90 },
		fuel = 110,
		vmin = 180,
		bodies = {
			{ x = 520, y = 240, r = 9, density = 8 },
		},
		goal = { x1 = 260, y1 = 420, x2 = 460, y2 = 420 },
	},
	{
		name = "DARK COMPANION",
		-- thread the gap between a bright planet and a black hole
		bounds = { w = 800, h = 480 },
		ship = { x = 80, y = 100, vx = 0, vy = 0, heading = 110 },
		fuel = 180,
		vmin = 140,
		bodies = {
			{ x = 300, y = 200, r = 16, density = 1.2 },
			{ x = 520, y = 330, r = 8, density = 7 },
		},
		goal = { x1 = 720, y1 = 100, x2 = 720, y2 = 220 },
	},
	{
		name = "PERIHELION",
		-- set finale: moving spawn, massive black hole, forced grazing burn
		bounds = { w = 1200, h = 720 },
		ship = { x = 120, y = 600, vx = 60, vy = -40, heading = 90 },
		fuel = 120,
		vmin = 200,
		bodies = {
			{ x = 600, y = 360, r = 12, density = 9 },
		},
		goal = { x1 = 1080, y1 = 240, x2 = 1080, y2 = 480 },
	},

	-- ============ SET 3 (11-15): wormholes ============
	{
		name = "SHORTCUT",
		-- a near-full-height wall seals the right side; the wormhole bridges it
		bounds = { w = 600, h = 360 },
		ship = { x = 100, y = 180, vx = 0, vy = 0, heading = 90 },
		fuel = 100,
		vmin = 165,
		bodies = {
			{ x = 470, y = 250, r = 14, density = 1.4 },
		},
		wormholes = {
			{ ax = 100, ay = 300, bx = 470, by = 60, r = 10, density = 2.5 },
		},
		goal = { x1 = 380, y1 = 20, x2 = 380, y2 = 340 },
	},
	{
		name = "THREAD THE NEEDLE",
		-- velocity carries through the hole: aim BEFORE you enter
		bounds = { w = 600, h = 360 },
		ship = { x = 80, y = 100, vx = 0, vy = 0, heading = 135 },
		fuel = 160,
		vmin = 110,
		bodies = {
			{ x = 300, y = 80, r = 12, density = 1.2 },
		},
		wormholes = {
			{ ax = 150, ay = 260, bx = 430, by = 120, r = 10, density = 2.5 },
		},
		goal = { x1 = 540, y1 = 60, x2 = 540, y2 = 180 },
	},
	{
		name = "ROUND TRIP",
		-- out through B, a full swing around the planet (> trap window), back through B
		bounds = { w = 800, h = 480 },
		ship = { x = 100, y = 240, vx = 0, vy = 0, heading = 150 },
		fuel = 130,
		vmin = 160,
		bodies = {
			{ x = 560, y = 320, r = 15, density = 1.5 },
		},
		wormholes = {
			{ ax = 140, ay = 360, bx = 560, by = 140, r = 10, density = 2.5 },
		},
		goal = { x1 = 60, y1 = 280, x2 = 60, y2 = 440 },
	},
	{
		name = "SWITCHBOARD",
		-- two pairs chained; the pairs are told apart by size
		bounds = { w = 1000, h = 600 },
		ship = { x = 100, y = 300, vx = 0, vy = 0, heading = 60 },
		fuel = 180,
		vmin = 120,
		bodies = {
			{ x = 400, y = 300, r = 14, density = 1.3 },
		},
		wormholes = {
			{ ax = 200, ay = 150, bx = 520, by = 450, r = 10, density = 2.5 },
			{ ax = 620, ay = 430, bx = 880, by = 140, r = 13, density = 2.0 },
		},
		goal = { x1 = 940, y1 = 60, x2 = 940, y2 = 200 },
	},
	{
		name = "GRAND CENTRAL",
		-- finale: the wormhole delivers you onto a black-hole periapsis; burn the tank
		bounds = { w = 1200, h = 720 },
		ship = { x = 120, y = 360, vx = 0, vy = 0, heading = 90 },
		fuel = 130,
		vmin = 220,
		bodies = {
			{ x = 300, y = 160, r = 13, density = 1.2 },
			{ x = 600, y = 360, r = 11, density = 8 },
		},
		wormholes = {
			{ ax = 160, ay = 560, bx = 600, by = 120, r = 10, density = 2.5 },
		},
		goal = { x1 = 1100, y1 = 240, x2 = 1100, y2 = 460 },
	},

	-- ============ SET 4 (16-20): moving bodies ============
	-- orbit = { cx, cy, a, b, period, phase } rides a parametric ellipse
	-- (radius = circular shorthand). free = true + vx/vy is a fully simulated
	-- planet: it feels every body, warps through wormholes, and merges on contact.
	{
		name = "CLOCKWORK",
		-- first moving body: a moon sweeps the lane to the goal; time the gap
		bounds = { w = 600, h = 360 },
		ship = { x = 60, y = 180, vx = 0, vy = 0, heading = 90 },
		fuel = 220,
		vmin = 110,
		bodies = {
			{ x = 300, y = 180, r = 14, density = 1.3 },
			{ r = 7, density = 1.5, orbit = { cx = 300, cy = 180, radius = 90, period = 6, phase = 0 } },
		},
		goal = { x1 = 540, y1 = 100, x2 = 540, y2 = 260 },
	},
	{
		name = "APSIDES",
		-- the guard rides an ELLIPSE: fast and close at periapsis, slow and far
		-- at apoapsis - cross the corridor while it lingers out wide
		bounds = { w = 600, h = 360 },
		ship = { x = 60, y = 300, vx = 0, vy = 0, heading = 60 },
		fuel = 220,
		vmin = 115,
		bodies = {
			{ x = 300, y = 180, r = 12, density = 1.2 },
			{ r = 9, density = 2.0, orbit = { cx = 300, cy = 180, a = 160, b = 60, period = 7, phase = 0 } },
		},
		goal = { x1 = 540, y1 = 60, x2 = 540, y2 = 200 },
	},
	{
		name = "ACCRETION",
		-- two free planets spiral together and MERGE (~3.5s in); the newborn
		-- heavyweight is your sling anchor
		bounds = { w = 800, h = 480 },
		ship = { x = 80, y = 240, vx = 0, vy = 0, heading = 90 },
		fuel = 200,
		vmin = 130,
		bodies = {
			{ x = 350, y = 200, r = 10, density = 1.4, free = true, vx = -6.25, vy = 7.81 },
			{ x = 450, y = 280, r = 10, density = 1.4, free = true, vx = 6.25, vy = -7.81 },
		},
		goal = { x1 = 740, y1 = 160, x2 = 740, y2 = 320 },
	},
	{
		name = "TIDAL LOCK",
		-- rails + wormhole: build speed on the long runway into the near mouth,
		-- then ride the exit lane past the swinging moon to the wall
		bounds = { w = 800, h = 480 },
		ship = { x = 80, y = 100, vx = 0, vy = 0, heading = 90 },
		fuel = 170,
		vmin = 140,
		bodies = {
			{ x = 430, y = 330, r = 14, density = 1.3 },
			{ r = 8, density = 2.0, orbit = { cx = 430, cy = 330, radius = 120, period = 5, phase = 0 } },
		},
		wormholes = {
			{ ax = 320, ay = 100, bx = 600, by = 240, r = 10, density = 2.5 },
		},
		goal = { x1 = 740, y1 = 150, x2 = 740, y2 = 330 },
	},
	{
		name = "COALESCENCE",
		-- finale: a pebble falls into the black hole (feeding it), a free planet
		-- orbits it as a roving hazard, and the wormhole still runs express
		bounds = { w = 1200, h = 720 },
		ship = { x = 100, y = 360, vx = 0, vy = 0, heading = 90 },
		fuel = 140,
		vmin = 210,
		bodies = {
			{ x = 600, y = 360, r = 11, density = 8 },
			{ x = 900, y = 360, r = 10, density = 1.5, free = true, vx = 0, vy = -45 },
			{ x = 600, y = 160, r = 7, density = 1.2, free = true, vx = 15, vy = 0 },
		},
		wormholes = {
			{ ax = 150, ay = 600, bx = 1050, by = 120, r = 10, density = 2.5 },
		},
		goal = { x1 = 1140, y1 = 240, x2 = 1140, y2 = 480 },
	},
}
