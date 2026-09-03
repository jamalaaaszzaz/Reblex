--============================================================--
--  MORPH LAB FE - muuttaa hahmosi ajoneuvoiksi / elaimiksi
--
--  100% FE: ei luoda yhtaan uutta partia, kaikki tehaan oman
--  hahmon raajoille jokaisessa Stepped-framessa -> kaikki
--  pelaajat nakevat muodonmuutoksen.
--
--  RIGIT:
--    R6 kaytetaan aina kun mahdollista (tarkin muoto)
--    R15 toimii varavirtana: raajaketjut (ylakasi-alakasi-kasi)
--    muodostavat mastot, potkurit, korvat ja jalat
--
--  MOODIT:
--    HELICOPTER : vartalo=runko makuulla, paa=ohjaamo,
--                 o.kasi=masto, o.jalka=paapotkuri,
--                 v.kasi=hantapuomi, v.jalka=hantapotkuri
--    BUNNY      : kadet=korvat (jousitettu heilunta),
--                 jalat=potkujalat, pomppufysiikka
--    DOG        : neljajalkainen, vinottainen rava-askel,
--                 hyppy=karkaus, alas=istuminen
--    MONSTER    : raskas hahmo, keinunta, lysahtavat kadet,
--                 special=murina
--
--  OHJAUS:
--    WASD            = liiku
--    HYPPY (space)   = moodikohtainen (nousu / pomppu / karkaus)
--    ALAS-nappi      = moodikohtainen (lasku / kyykky / istu)
--                      (nappi ilmestyy hypyn viereen, PC:lla CTRL)
--    SPECIAL         = moodikohtainen erikoisanimaatio
--    RightShift      = piilota / nayta GUI
--============================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

--====================== ASETUKSET ===========================--
local CFG = {
	-- heli
	ForwardSpeed   = 30,
	BackwardSpeed  = 14,
	ClimbSpeed     = 20,
	DescendSpeed   = 18,
	Acceleration   = 4,
	ForwardTilt    = 22,
	BankTilt       = 14,
	HoverBob       = 0.8,
	MainRotorIdle  = 8,
	MainRotorMax   = 30,
	MainRotorMin   = 5,
	TailRotorIdle  = 7,
	TailRotorMax   = 30,
	TailRotorGain  = 0.9,
	RotorResponse  = 2.6,
	-- pupu
	BunnySpeed     = 24,
	BunnyHop       = 13,
	BunnyFall      = -6,
	BunnyBigJump   = 16,
	BunnyLean      = 30,
	EarStiffness   = 110,
	EarDamping     = 9,
	EarAccelGain   = 0.0016,
	-- koira
	DogSpeed       = 36,
	DogLeap        = 14,
	-- monsteri
	MonsterSpeed   = 11,
	MonsterSlam    = 11,
	-- special kestot
	SpecialDuration = { HELI = 2.4, BUNNY = 1.3, DOG = 2.0, MONSTER = 1.9 },
}

local MODES = {
	{ id = "HELI",    name = "HELICOPTER", special = "CRASHOUT", down = "DESCEND" },
	{ id = "BUNNY",   name = "BUNNY",      special = "THUMP",    down = "DUCK"    },
	{ id = "DOG",     name = "DOG",        special = "BOW",      down = "SIT"     },
	{ id = "MONSTER", name = "MONSTER",    special = "ROAR",     down = "CROUCH"  },
}

--======================== TILA ==============================--
local state = {
	enabled     = false,
	mode        = "HELI",
	special     = false,
	specialT    = 0,
	elapsed     = 0,
	-- heli
	rotorAngle  = 0,
	tailAngle   = 0,
	mainSpeed   = CFG.MainRotorIdle,
	tailSpeed   = CFG.TailRotorIdle,
	-- yleinen liike
	velocity    = Vector3.zero,
	look        = Vector3.new(0, 0, -1),
	downHeld    = false,
	thumpPulse  = 0,
	-- pupu
	hopPhase    = 0,
	liftPos     = 0,
	earAngle    = 0,
	earVel      = 0,
	prevVy      = 0,
	squash      = 0,
	-- koira / monsteri
	gaitPhase   = 0,
}

local isR15 = false
local P = {} -- osat: hrp, torso, head, armR, armL, legR, legL (R6)
             -- R15: + lowerTorso, armRChain{}, armLChain{}, legRChain{}, legLChain{}
local char, humanoid, animator, animateScript
local bodyVelocity, bodyGyro
local rng = Random.new()

--====================== APURIT ==============================--
local function damp(a, b, k, dt)
	return a + (b - a) * (1 - math.exp(-k * dt))
end

local function dampV3(a, b, k, dt)
	return a:Lerp(b, 1 - math.exp(-k * dt))
end

local function shakeCF(posMag, rotMag)
	return CFrame.new(
		(rng:NextNumber() - 0.5) * 2 * posMag,
		(rng:NextNumber() - 0.5) * 2 * posMag,
		(rng:NextNumber() - 0.5) * 2 * posMag
	) * CFrame.Angles(
		(rng:NextNumber() - 0.5) * 2 * rotMag,
		(rng:NextNumber() - 0.5) * 2 * rotMag,
		(rng:NextNumber() - 0.5) * 2 * rotMag
	)
end

-- asettaa osaketjun perakkain root-framen -Y suuntaan,
-- palauttaa viimeisen osan framen (ketjun paa)
local function chain(root, parts)
	local cur = root
	local prevHalf = 0
	for _, part in ipairs(parts) do
		cur = cur * CFrame.new(0, -(prevHalf + part.Size.Y / 2), 0)
		part.CFrame = cur
		prevHalf = part.Size.Y / 2
	end
	return cur
end

local function bindCharacter(c)
	char = c
	humanoid = c:WaitForChild("Humanoid")
	P = {}
	P.hrp = c:WaitForChild("HumanoidRootPart")
	P.head = c:WaitForChild("Head")
	isR15 = humanoid.RigType == Enum.HumanoidRigType.R15

	if isR15 then
		P.torso = c:WaitForChild("UpperTorso")
		P.lowerTorso = c:WaitForChild("LowerTorso")
		P.armRChain = { c:WaitForChild("RightUpperArm"), c:WaitForChild("RightLowerArm"), c:WaitForChild("RightHand") }
		P.armLChain = { c:WaitForChild("LeftUpperArm"), c:WaitForChild("LeftLowerArm"), c:WaitForChild("LeftHand") }
		P.legRChain = { c:WaitForChild("RightUpperLeg"), c:WaitForChild("RightLowerLeg"), c:WaitForChild("RightFoot") }
		P.legLChain = { c:WaitForChild("LeftUpperLeg"), c:WaitForChild("LeftLowerLeg"), c:WaitForChild("LeftFoot") }
	else
		P.torso = c:WaitForChild("Torso")
		P.armR = c:WaitForChild("Right Arm")
		P.armL = c:WaitForChild("Left Arm")
		P.legR = c:WaitForChild("Right Leg")
		P.legL = c:WaitForChild("Left Leg")
	end

	animator = humanoid:WaitForChild("Animator")
	animateScript = c:FindFirstChild("Animate")
end

local function allParts()
	local list = { P.head, P.torso }
	if isR15 then
		table.insert(list, P.lowerTorso)
		for _, g in ipairs({ P.armRChain, P.armLChain, P.legRChain, P.legLChain }) do
			for _, p in ipairs(g) do table.insert(list, p) end
		end
	else
		for _, p in ipairs({ P.armR, P.armL, P.legR, P.legL }) do
			table.insert(list, p)
		end
	end
	return list
end

local function stopAnimations()
	if not animator then return end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
	end
end

local function setBodyCollisions(value)
	for _, p in ipairs(allParts()) do
		if p then p.CanCollide = value end
	end
end

--====================== PAALLA / POIS =======================--
local updateToggleButton
local updateModeButtons
local descendBtn
local specialBtn
local statusLabel

local function modeInfo()
	for _, m in ipairs(MODES) do
		if m.id == state.mode then return m end
	end
	return MODES[1]
end

local function enable()
	if state.enabled then return end
	if not humanoid then return end

	state.enabled = true
	state.special = false
	state.specialT = 0
	state.elapsed = 0
	state.velocity = Vector3.zero
	state.mainSpeed = CFG.MainRotorIdle
	state.tailSpeed = CFG.TailRotorIdle
	state.earAngle, state.earVel = 0, 0
	state.hopPhase, state.gaitPhase = 0, 0
	state.thumpPulse = 0

	if animateScript then animateScript.Disabled = true end
	stopAnimations()

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	for _, st in ipairs({
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.Jumping,
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.Swimming,
	}) do
		humanoid:SetStateEnabled(st, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	setBodyCollisions(false)

	P.hrp.CFrame = P.hrp.CFrame + Vector3.new(0, 2.5, 0)

	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	bodyVelocity.Velocity = Vector3.zero
	bodyVelocity.Parent = P.hrp

	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	bodyGyro.D = 800
	bodyGyro.P = 1e5
	bodyGyro.CFrame = P.hrp.CFrame
	bodyGyro.Parent = P.hrp

	if descendBtn then
		descendBtn.Visible = true
		descendBtn.Text = "v\n" .. modeInfo().down
	end
	if specialBtn then
		specialBtn.Text = modeInfo().special
	end
	updateToggleButton()
end

local function disable()
	if not state.enabled then return end
	state.enabled = false
	state.special = false
	state.downHeld = false

	if bodyVelocity then bodyVelocity:Destroy(); bodyVelocity = nil end
	if bodyGyro then bodyGyro:Destroy(); bodyGyro = nil end

	if humanoid and humanoid.Parent then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
		setBodyCollisions(false)
	end

	if animateScript then animateScript.Disabled = false end
	stopAnimations()

	if descendBtn then descendBtn.Visible = false end
	updateToggleButton()
end

local function triggerSpecial()
	if not state.enabled or state.special then return end
	state.special = true
	state.specialT = 0
	if state.mode == "BUNNY" then
		state.thumpPulse = CFG.BunnyBigJump * 1.2
		state.earVel = state.earVel + 5
	end
end

--============================================================--
--                     POSEN MUOTOILU
--============================================================--

local function poseHeli(base, t)
	local crash = state.special

	local torsoCF = base
	if crash then torsoCF = torsoCF * shakeCF(0.1, 0.09) end

	-- base-frame heleissa: +Z=ylos, -Y=hanta, +Y=nokka
	local mastRoot = base * CFrame.new(0, -0.45, 1.05)
	local tailRoot = base * CFrame.new(0, -1.05, 0.3)

	if isR15 then
		P.torso.CFrame = torsoCF
		P.lowerTorso.CFrame = base * CFrame.new(0, -0.55, 0.05)

		-- paa = ohjaamo
		if crash then
			P.head.CFrame = base * CFrame.new(0, 1.30, 0.55)
				* CFrame.Angles(math.rad(125) + math.rad(6) * math.sin(t * 16), 0, 0)
				* shakeCF(0.07, 0.1)
		else
			P.head.CFrame = base * CFrame.new(0, 1.55, 0.28)
				* CFrame.Angles(math.rad(90), 0, 0)
		end

		-- o.kaden ketju = masto ylos (Z-kaanto: -Y -> ylos)
		local mastBase
		if crash then
			mastBase = mastRoot * CFrame.Angles(math.rad(-155), 0, math.pi)
		else
			mastBase = mastRoot * CFrame.Angles(math.rad(-2.5) * math.sin(t * 2.3), 0, math.pi)
		end
		local mastEnd = chain(mastBase, P.armRChain)

		-- o.jalan ketju = paapotkuri (3-osainen lapa)
		local rotorRoot = mastEnd * CFrame.new(0, -0.45, 0)
			* CFrame.Angles(0, state.rotorAngle, math.rad(90))
		chain(rotorRoot, P.legRChain)

		-- v.kaden ketju = hantapuomi
		local boomRoot = tailRoot
		if crash then boomRoot = tailRoot * CFrame.Angles(math.rad(40), 0, 0) end
		local boomEnd = chain(boomRoot, P.armLChain)

		-- v.jalan ketju = hantapotkuri
		local tailRotorRoot = boomEnd * CFrame.Angles(0, state.tailAngle, math.rad(90))
		chain(tailRotorRoot, P.legLChain)
	else
		P.torso.CFrame = torsoCF

		if crash then
			P.head.CFrame = base * CFrame.new(0, 1.30, 0.55)
				* CFrame.Angles(math.rad(125) + math.rad(6) * math.sin(t * 16), 0, 0)
				* shakeCF(0.07, 0.1)
		else
			P.head.CFrame = base * CFrame.new(0, 1.55, 0.28)
				* CFrame.Angles(math.rad(90), 0, 0)
		end

		-- o.kasi = masto
		if crash then
			P.armR.CFrame = mastRoot * CFrame.Angles(math.rad(155), 0, 0) * CFrame.new(0, 1, 0)
		else
			P.armR.CFrame = mastRoot
				* CFrame.Angles(math.rad(90) + math.rad(2.5) * math.sin(t * 2.3), 0, 0)
				* CFrame.new(0, 1, 0)
		end

		-- o.jalka = paapotkuri
		local bladeBase = mastRoot * CFrame.new(0, 0, 2.05)
			* CFrame.Angles(0, 0, state.rotorAngle)
		P.legR.CFrame = bladeBase * CFrame.Angles(0, 0, math.rad(-90))

		-- v.kasi = hantapuomi
		if crash then
			P.armL.CFrame = tailRoot * CFrame.Angles(math.rad(220), 0, 0) * CFrame.new(0, 1, 0)
		else
			P.armL.CFrame = tailRoot * CFrame.Angles(math.rad(180), 0, 0) * CFrame.new(0, 1, 0)
		end

		-- v.jalka = hantapotkuri
		local tailSpin = tailRoot * CFrame.new(0, -2.15, 0.05)
			* CFrame.Angles(0, state.tailAngle, 0)
		P.legL.CFrame = tailSpin * CFrame.Angles(math.rad(90), 0, 0)
	end
end

local function poseBunny(base, t)
	local lift = state.liftPos
	local sq = state.squash
	local earBack = 0.22 + state.earAngle
	local twitchY = math.rad(3) * math.sin(t * 1.7) + math.rad(1.5) * math.sin(t * 5.3)
	local headP = math.rad(4) * math.sin(t * 2.9)

	if state.special then -- THUMP: kyykisty ja jytkayta
		sq = sq + 0.15 * math.abs(math.sin(state.specialT * 14))
	end

	if isR15 then
		P.lowerTorso.CFrame = base * CFrame.new(0, -sq, 0)
		P.torso.CFrame = base * CFrame.new(0, 0.55 - sq, -0.02)
		P.head.CFrame = base * CFrame.new(0, 1.32 - sq, -0.08)
			* CFrame.Angles(headP, twitchY, 0)

		-- korvat: kasiketjut ylos (Z-kaanto + sivulle vino)
		for side, chainParts in pairs({ [-1] = P.armLChain, [1] = P.armRChain }) do
			local earRoot = base * CFrame.new(side * 0.28, 1.18 - sq, 0.12)
				* CFrame.Angles(earBack + headP, 0, math.pi - side * 0.14)
			chain(earRoot, chainParts)
		end

		-- jalat: ketjut, kyykky <-> ojennus
		local legA = math.rad(50 - 85 * lift)
		local hipL = base * CFrame.new(-0.42, -0.55 - sq, 0.05) * CFrame.Angles(legA, 0, 0)
		local hipR = base * CFrame.new(0.42, -0.55 - sq, 0.05) * CFrame.Angles(legA, 0, 0)
		chain(hipL, P.legLChain)
		chain(hipR, P.legRChain)
	else
		P.torso.CFrame = base * CFrame.new(0, -sq, 0)
		P.head.CFrame = base * CFrame.new(0, 1.5 - sq, -0.08)
			* CFrame.Angles(headP, twitchY, 0)

		-- korvat: kadet ylos, heilunta earBack-kulmalla
		local earL = base * CFrame.new(-0.32, 1.05 - sq, 0.12)
			* CFrame.Angles(earBack, math.rad(-8), 0)
		local earR = base * CFrame.new(0.32, 1.05 - sq, 0.12)
			* CFrame.Angles(earBack, math.rad(8), 0)
		P.armL.CFrame = earL * CFrame.new(0, 1, 0)
		P.armR.CFrame = earR * CFrame.new(0, 1, 0)

		-- jalat: R6-osat (osoittavat +Y:han), kyykky 215 -> ojennus 140
		local legA = math.rad(215 - 75 * lift)
		P.legL.CFrame = base * CFrame.new(-0.5, -0.62 - sq, 0.08)
			* CFrame.Angles(legA, 0, 0) * CFrame.new(0, 1, 0)
		P.legR.CFrame = base * CFrame.new(0.5, -0.62 - sq, 0.08)
			* CFrame.Angles(legA, 0, 0) * CFrame.new(0, 1, 0)
	end
end

local function poseDog(base, t)
	local g = state.gaitPhase * math.pi * 2
	local swing = math.rad(32) * math.sin(g)
	local swingOpp = -swing
	local pant = math.rad(5) * math.sin(t * 6)
	local bow = state.special -- BOW: etu alas, takamus ylos, heilunta

	if bow then
		swing = math.rad(-65) -- etujalat suoraksi eteen
		swingOpp = math.rad(20) * math.sin(t * 14) -- takaosa heiluu
		pant = math.rad(18)
	end

	-- base-frame koirassa: +Y=nokka, +Z=ylos, -Z=alas
	if isR15 then
		P.lowerTorso.CFrame = base * CFrame.new(0, -0.5, 0.05)
		P.torso.CFrame = base * CFrame.new(0, 0.55, 0.02)
		P.head.CFrame = base * CFrame.new(0, 1.15, 0.3)
			* CFrame.Angles(math.rad(78) + pant, math.rad(4) * math.sin(t * 2.2), 0)

		local shL = base * CFrame.new(-0.5, 0.62, -0.2) * CFrame.Angles(math.rad(90) + swingOpp, 0, 0)
		local shR = base * CFrame.new(0.5, 0.62, -0.2) * CFrame.Angles(math.rad(90) + swing, 0, 0)
		local hipL = base * CFrame.new(-0.5, -0.55, -0.2) * CFrame.Angles(math.rad(90) + swing, 0, 0)
		local hipR = base * CFrame.new(0.5, -0.55, -0.2) * CFrame.Angles(math.rad(90) + swingOpp, 0, 0)
		chain(shL, P.armLChain)
		chain(shR, P.armRChain)
		chain(hipL, P.legLChain)
		chain(hipR, P.legRChain)
	else
		P.torso.CFrame = base
		P.head.CFrame = base * CFrame.new(0, 1.1, 0.3)
			* CFrame.Angles(math.rad(75) + pant, math.rad(4) * math.sin(t * 2.2), 0)

		-- etujalat (kadet): alas + keinu; takajalat vastavaheessa (vinottain)
		P.armR.CFrame = base * CFrame.new(0.55, 0.75, -0.25)
			* CFrame.Angles(math.rad(-90) + swing, 0, 0) * CFrame.new(0, 1, 0)
		P.armL.CFrame = base * CFrame.new(-0.55, 0.75, -0.25)
			* CFrame.Angles(math.rad(-90) + swingOpp, 0, 0) * CFrame.new(0, 1, 0)
		P.legR.CFrame = base * CFrame.new(0.5, -0.75, -0.25)
			* CFrame.Angles(math.rad(-90) + swingOpp, 0, 0) * CFrame.new(0, 1, 0)
		P.legL.CFrame = base * CFrame.new(-0.5, -0.75, -0.25)
			* CFrame.Angles(math.rad(-90) + swing, 0, 0) * CFrame.new(0, 1, 0)
	end
end

local function poseMonster(base, t)
	local g = state.gaitPhase * math.pi * 2
	local sway = math.rad(4) * math.sin(t * 1.4)
	local armSwing = math.rad(14) * math.sin(g)
	local legSwing = math.rad(10) * math.sin(g)
	local roar = state.special -- ROAR: paa taakse, kadet ylos, tarina

	if isR15 then
		P.lowerTorso.CFrame = base
		P.torso.CFrame = base * CFrame.new(0, 0.55, -0.04) * CFrame.Angles(math.rad(8), sway, 0)

		if roar then
			P.head.CFrame = base * CFrame.new(0, 1.5, 0.05)
				* CFrame.Angles(math.rad(-38) + math.rad(5) * math.sin(t * 20), 0, 0)
				* shakeCF(0.05, 0.06)
			for side, chainParts in pairs({ [-1] = P.armLChain, [1] = P.armRChain }) do
				local sh = base * CFrame.new(side * 0.85, 0.85, -0.05)
					* CFrame.Angles(math.rad(-140 + 8 * math.sin(t * 18 + side)), side * math.rad(18), 0)
				chain(sh, chainParts)
			end
		else
			P.head.CFrame = base * CFrame.new(0, 1.48, -0.3)
				* CFrame.Angles(math.rad(24), sway, 0)
			local shL = base * CFrame.new(-0.85, 0.85, -0.08)
				* CFrame.Angles(math.rad(22) + armSwing, math.rad(-6), 0)
			local shR = base * CFrame.new(0.85, 0.85, -0.08)
				* CFrame.Angles(math.rad(22) - armSwing, math.rad(6), 0)
			chain(shL, P.armLChain)
			chain(shR, P.armRChain)
		end

		local hipL = base * CFrame.new(-0.45, -0.5, 0) * CFrame.Angles(legSwing, 0, 0)
		local hipR = base * CFrame.new(0.45, -0.5, 0) * CFrame.Angles(-legSwing, 0, 0)
		chain(hipL, P.legLChain)
		chain(hipR, P.legRChain)
	else
		P.torso.CFrame = base * CFrame.Angles(0, sway, 0)

		if roar then
			P.head.CFrame = base * CFrame.new(0, 1.5, 0.1)
				* CFrame.Angles(math.rad(-40) + math.rad(5) * math.sin(t * 20), 0, 0)
				* shakeCF(0.05, 0.06)
			P.armL.CFrame = base * CFrame.new(-0.8, 0.6, 0)
				* CFrame.Angles(math.rad(-150 + 8 * math.sin(t * 18)), 0, math.rad(-15))
				* CFrame.new(0, 1, 0)
			P.armR.CFrame = base * CFrame.new(0.8, 0.6, 0)
				* CFrame.Angles(math.rad(-150 - 8 * math.sin(t * 18)), 0, math.rad(15))
				* CFrame.new(0, 1, 0)
		else
			P.head.CFrame = base * CFrame.new(0, 1.45, -0.28)
				* CFrame.Angles(math.rad(22), sway, 0)
			-- kadet roikkuvat pitkina eteen-alas
			P.armL.CFrame = base * CFrame.new(-0.8, 0.5, -0.05)
				* CFrame.Angles(math.rad(200) - armSwing, 0, 0) * CFrame.new(0, 1, 0)
			P.armR.CFrame = base * CFrame.new(0.8, 0.5, -0.05)
				* CFrame.Angles(math.rad(200) + armSwing, 0, 0) * CFrame.new(0, 1, 0)
		end

		P.legL.CFrame = base * CFrame.new(-0.5, -0.95, 0)
			* CFrame.Angles(math.rad(180) - legSwing, 0, 0) * CFrame.new(0, 1, 0)
		P.legR.CFrame = base * CFrame.new(0.5, -0.95, 0)
			* CFrame.Angles(math.rad(180) + legSwing, 0, 0) * CFrame.new(0, 1, 0)
	end
end

--============================================================--
--                       PAALUUPPI
--============================================================--
RunService.Stepped:Connect(function(_, dt)
	if not state.enabled then return end
	if not P.hrp or P.hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end

	state.elapsed = state.elapsed + dt
	local t = state.elapsed

	stopAnimations()
	if humanoid.Sit then humanoid.Sit = false end

	-- suunta kamerasta
	local cam = workspace.CurrentCamera
	local camLook = cam and cam.CFrame.LookVector or P.hrp.CFrame.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 1e-3 then
		flatLook = state.look
	else
		flatLook = flatLook.Unit
	end
	state.look = dampV3(state.look, flatLook, 6, dt)
	local look = state.look.Unit
	local right = look:Cross(Vector3.yAxis)

	-- input
	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	local upInput = humanoid.Jump
	local downInput = state.downHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)

	local desired
	local gyroCF

	if state.mode == "HELI" then
		---------------- FYSIIKKA: HELIKOPTERI ----------------
		local spd = CFG.ForwardSpeed
		if flat.Magnitude > 1e-3 and flat.Unit:Dot(look) < -0.3 then
			spd = CFG.BackwardSpeed
		end
		local vertical = 0
		if upInput and not downInput then
			vertical = CFG.ClimbSpeed
		elseif downInput and not upInput then
			vertical = -CFG.DescendSpeed
		else
			vertical = math.sin(t * 2.1) * CFG.HoverBob
		end
		if state.special then
			vertical = vertical + (rng:NextNumber() - 0.5) * 10
		end
		desired = flat * spd + Vector3.new(0, vertical, 0)
		state.velocity = dampV3(state.velocity, desired, CFG.Acceleration, dt)

		local fSpeed = state.velocity:Dot(look)
		local sSpeed = state.velocity:Dot(right)
		local pitchExtra = -math.rad(CFG.ForwardTilt) * math.clamp(fSpeed / CFG.ForwardSpeed, -1, 1)
		local roll = -math.rad(CFG.BankTilt) * math.clamp(sSpeed / CFG.ForwardSpeed, -1, 1)

		local jx, jy, jz = 0, 0, 0
		if state.special then
			jx = (rng:NextNumber() - 0.5) * math.rad(10)
			jy = (rng:NextNumber() - 0.5) * math.rad(10)
			jz = (rng:NextNumber() - 0.5) * math.rad(10)
		end

		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look)
			* CFrame.Angles(math.rad(-90) + pitchExtra + jx, 0, 0)
			* CFrame.Angles(0, roll + jy, 0)
			* CFrame.Angles(0, 0, jz)

		-- potkurit
		local mainTarget = CFG.MainRotorIdle
		if upInput then mainTarget = CFG.MainRotorMax
		elseif downInput then mainTarget = CFG.MainRotorMin end
		if state.special then mainTarget = 4 + 9 * math.abs(math.sin(t * 6.5)) end
		local tailTarget = math.clamp(
			CFG.TailRotorIdle + CFG.TailRotorGain * math.max(0, fSpeed), 0, CFG.TailRotorMax)
		if state.special then
			tailTarget = tailTarget * (0.4 + 0.6 * math.abs(math.sin(t * 9)))
		end
		state.mainSpeed = damp(state.mainSpeed, mainTarget, CFG.RotorResponse, dt)
		state.tailSpeed = damp(state.tailSpeed, tailTarget, CFG.RotorResponse, dt)
		state.rotorAngle = (state.rotorAngle + state.mainSpeed * dt) % (math.pi * 2)
		state.tailAngle = (state.tailAngle + state.tailSpeed * dt) % (math.pi * 2)

	elseif state.mode == "BUNNY" then
		---------------- FYSIIKKA: PUPU ----------------
		local hSpeed = downInput and 0 or CFG.BunnySpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		-- pompun tahti skaalautuu vauhtiin
		if spd > 1 then
			state.hopPhase = (state.hopPhase + dt * (1.5 + spd / 12)) % 1
		else
			state.hopPhase = (state.hopPhase + dt * 0.8) % 1
		end

		local s = math.sin(state.hopPhase * math.pi * 2)
		state.liftPos = math.clamp(s, 0, 1)
		local vy
		if downInput then
			vy = 0 -- kyykky paikallaan
		elseif spd > 1 or upInput then
			vy = s > 0 and (s ^ 1.3) * CFG.BunnyHop or CFG.BunnyFall
		else
			vy = math.sin(t * 3.2) * 0.6 -- hengitys
		end
		if upInput then
			vy = math.max(vy, CFG.BunnyBigJump)
		end
		if state.thumpPulse > 0 then
			vy = math.max(vy, state.thumpPulse)
			state.thumpPulse = math.max(0, state.thumpPulse - dt * 40)
		end

		-- korvajousi: reagoi pystykiihtyvyyteen
		local acc = math.clamp((vy - state.prevVy) / math.max(dt, 1e-4), -220, 220)
		state.prevVy = vy
		state.earVel = state.earVel
			+ (-CFG.EarStiffness * state.earAngle - CFG.EarDamping * state.earVel) * dt
			+ acc * CFG.EarAccelGain
		state.earAngle = math.clamp(state.earAngle + state.earVel * dt, -0.5, 0.85)

		-- squash & stretch
		local targetSquash = (s < 0 and spd > 1) and 0.16 or 0
		if state.special then targetSquash = targetSquash + 0.1 end
		state.squash = damp(state.squash, targetSquash, 14, dt)

		desired = horizV + Vector3.new(0, vy, 0)
		state.velocity = dampV3(state.velocity, desired, 8, dt)

		local lean = math.rad(CFG.BunnyLean) * math.clamp(spd / CFG.BunnySpeed, 0, 1)
		if downInput then lean = math.rad(12) end
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(-lean, 0, 0)

	elseif state.mode == "DOG" then
		---------------- FYSIIKKA: KOIRA ----------------
		local hSpeed = downInput and 0 or CFG.DogSpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		if spd > 1 then
			state.gaitPhase = (state.gaitPhase + dt * (1.6 + spd / 9)) % 1
		end
		local trot = math.abs(math.sin(state.gaitPhase * math.pi * 2))
		local vy = spd > 1 and (trot * 2.4 - 1.2) or math.sin(t * 2.5) * 0.4
		if upInput then vy = math.max(vy, CFG.DogLeap) end
		if downInput then vy = 0 end

		desired = horizV + Vector3.new(0, vy, 0)
		state.velocity = dampV3(state.velocity, desired, 7, dt)

		-- makaa, hieman pystympi kuin heli; BOW: etupaata alas
		local pitch = math.rad(-78)
		if downInput then pitch = math.rad(-42) end -- istuminen
		if state.special then pitch = math.rad(-96) end -- kumarrus
		local sway = math.rad(3) * math.sin(t * 2)
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(pitch, 0, sway)

	else -- MONSTER
		---------------- FYSIIKKA: MONSTERI ----------------
		local hSpeed = downInput and CFG.MonsterSpeed * 0.4 or CFG.MonsterSpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		if spd > 1 then
			state.gaitPhase = (state.gaitPhase + dt * (1.1 + spd / 10)) % 1
		end
		local stomp = math.abs(math.sin(state.gaitPhase * math.pi * 2))
		local vy = spd > 1 and (stomp * 1.6 - 0.8) or math.sin(t * 1.8) * 0.4
		if upInput then vy = math.max(vy, CFG.MonsterSlam) end
		if state.special then
			vy = vy + math.sin(t * 22) * 1.2
		end

		desired = horizV + Vector3.new(0, vy, 0)
		state.velocity = dampV3(state.velocity, desired, 5, dt)

		local lean = math.rad(-24)
		if downInput then lean = math.rad(-38) end
		local sway = math.rad(4) * math.sin(t * 1.4)
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(lean, 0, sway)
	end

	bodyVelocity.Velocity = state.velocity
	bodyGyro.CFrame = gyroCF

	-- special-ajastin
	if state.special then
		state.specialT = state.specialT + dt
		if state.specialT >= (CFG.SpecialDuration[state.mode] or 2) then
			state.special = false
		end
	end

	-- pose
	local base = P.hrp.CFrame
	if state.mode == "HELI" then
		poseHeli(base, t)
	elseif state.mode == "BUNNY" then
		poseBunny(base, t)
	elseif state.mode == "DOG" then
		poseDog(base, t)
	else
		poseMonster(base, t)
	end

	-- status
	if statusLabel then
		local extra = ""
		if state.mode == "HELI" then
			extra = string.format("  |  ROTOR %d%%", math.floor(state.mainSpeed / CFG.MainRotorMax * 100 + 0.5))
		elseif state.mode == "BUNNY" then
			extra = string.format("  |  HOP %d%%", math.floor(state.liftPos * 100 + 0.5))
		end
		statusLabel.Text = string.format(
			"%s  |  %d studs/s%s",
			modeInfo().name,
			math.floor(state.velocity.Magnitude + 0.5),
			extra
		)
	end
end)

--============================================================--
--                          GUI
--============================================================--
local gui = Instance.new("ScreenGui")
gui.Name = "MorphLabGUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local COLORS = {
	bg        = Color3.fromRGB(14, 16, 24),
	bgLight   = Color3.fromRGB(24, 27, 39),
	accent    = Color3.fromRGB(0, 170, 255),
	green     = Color3.fromRGB(46, 204, 113),
	red       = Color3.fromRGB(231, 76, 60),
	orange    = Color3.fromRGB(230, 126, 34),
	pillOff   = Color3.fromRGB(38, 42, 58),
	text      = Color3.fromRGB(235, 240, 255),
	textDim   = Color3.fromRGB(150, 158, 180),
}

local function roundify(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = obj
end

local function strokeify(obj, transparency, color)
	local s = Instance.new("UIStroke")
	s.Color = color or Color3.new(1, 1, 1)
	s.Transparency = transparency or 0.88
	s.Thickness = 1
	s.Parent = obj
	return s
end

local function gradientify(obj, topColor, bottomColor, rotation)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	g.Rotation = rotation or 90
	g.Parent = obj
end

local function makeDraggable(frame, handle)
	local dragging = false
	local dragStart, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- paakehys
local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 264, 0, 246)
main.Position = UDim2.new(0, 24, 0.5, -123)
main.BackgroundColor3 = COLORS.bg
main.BackgroundTransparency = 0.15
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui
roundify(main, 14)
strokeify(main, 0.85)
gradientify(main, Color3.fromRGB(22, 25, 36), Color3.fromRGB(12, 14, 21))

-- otsikkorivi
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = COLORS.bgLight
titleBar.BackgroundTransparency = 0.15
titleBar.BorderSizePixel = 0
titleBar.Parent = main
roundify(titleBar, 14)

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.new(0, 3, 0, 18)
accentBar.Position = UDim2.new(0, 12, 0.5, -9)
accentBar.BackgroundColor3 = COLORS.accent
accentBar.BorderSizePixel = 0
accentBar.Parent = titleBar
roundify(accentBar, 2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 1, 0)
title.Position = UDim2.new(0, 22, 0, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = COLORS.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "MORPH LAB  //  FE"
title.Parent = titleBar

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 24, 0, 24)
minBtn.Position = UDim2.new(1, -32, 0.5, -12)
minBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
minBtn.BackgroundTransparency = 0.9
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 15
minBtn.TextColor3 = COLORS.text
minBtn.Text = "-"
minBtn.BorderSizePixel = 0
minBtn.Parent = titleBar
roundify(minBtn, 8)

-- sisalto
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, 0, 1, -38)
content.Position = UDim2.new(0, 0, 0, 38)
content.BackgroundTransparency = 1
content.Parent = main

-- moodipainikkeet (pill-rivi)
local pillRow = Instance.new("Frame")
pillRow.Size = UDim2.new(1, -20, 0, 30)
pillRow.Position = UDim2.new(0, 10, 0, 8)
pillRow.BackgroundTransparency = 1
pillRow.Parent = content

local pillLayout = Instance.new("UIListLayout")
pillLayout.FillDirection = Enum.FillDirection.Horizontal
pillLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
pillLayout.Padding = UDim.new(0, 5)
pillLayout.Parent = pillRow

local pillBtns = {}
for _, m in ipairs(MODES) do
	local b = Instance.new("TextButton")
	b.Name = m.id
	b.Size = UDim2.new(0, 57, 1, 0)
	b.BackgroundColor3 = COLORS.pillOff
	b.BackgroundTransparency = 0.15
	b.Font = Enum.Font.GothamBold
	b.TextSize = 10
	b.TextColor3 = COLORS.textDim
	b.Text = m.id == "HELI" and "HELI" or m.name
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Parent = pillRow
	roundify(b, 15)
	pillBtns[m.id] = b

	b.MouseButton1Click:Connect(function()
		if state.mode == m.id then return end
		state.mode = m.id
		state.special = false
		state.velocity = Vector3.zero
		state.hopPhase, state.gaitPhase = 0, 0
		state.earAngle, state.earVel = 0, 0
		updateModeButtons()
		if specialBtn then specialBtn.Text = modeInfo().special end
		if descendBtn then descendBtn.Text = "v\n" .. modeInfo().down end
	end)
end

updateModeButtons = function()
	for id, b in pairs(pillBtns) do
		if id == state.mode then
			b.BackgroundColor3 = COLORS.accent
			b.TextColor3 = Color3.fromRGB(10, 12, 18)
			b.BackgroundTransparency = 0
		else
			b.BackgroundColor3 = COLORS.pillOff
			b.TextColor3 = COLORS.textDim
			b.BackgroundTransparency = 0.15
		end
	end
end
updateModeButtons()

-- status
statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 20)
statusLabel.Position = UDim2.new(0, 12, 0, 46)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 11
statusLabel.TextColor3 = COLORS.accent
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = "READY"
statusLabel.Parent = content

local function makeButton(text, color, posY, height)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -24, 0, height)
	b.Position = UDim2.new(0, 12, 0, posY)
	b.BackgroundColor3 = color
	b.BackgroundTransparency = 0.05
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = COLORS.text
	b.Text = text
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Parent = content
	roundify(b, 10)
	gradientify(b, color, color:Lerp(Color3.new(0, 0, 0), 0.25))
	return b
end

local toggleBtn = makeButton("ENABLE", COLORS.green, 70, 38)
specialBtn = makeButton(modeInfo().special, COLORS.orange, 114, 38)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -24, 0, 40)
hint.Position = UDim2.new(0, 12, 0, 158)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextColor3 = COLORS.textDim
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Text = "JUMP = ascend / hop / leap\n"
	.. "DOWN button (next to jump) or CTRL = lower / duck\n"
	.. "RightShift = hide this panel"
hint.Parent = content

updateToggleButton = function()
	if state.enabled then
		toggleBtn.Text = "DISABLE"
		toggleBtn.BackgroundColor3 = COLORS.red
	else
		toggleBtn.Text = "ENABLE"
		toggleBtn.BackgroundColor3 = COLORS.green
		if statusLabel then statusLabel.Text = "READY" end
	end
end

toggleBtn.MouseButton1Click:Connect(function()
	if state.enabled then disable() else enable() end
end)

specialBtn.MouseButton1Click:Connect(function()
	triggerSpecial()
end)

-- pienennys
local minimized = false
local fullSize = main.Size
local miniSize = UDim2.new(0, 264, 0, 38)
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	local target = minimized and miniSize or fullSize
	if minimized then
		content.Visible = false
		minBtn.Text = "+"
	else
		minBtn.Text = "-"
	end
	local tween = TweenService:Create(
		main,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = target }
	)
	tween:Play()
	if not minimized then
		tween.Completed:Connect(function()
			content.Visible = true
		end)
	end
end)

makeDraggable(main, titleBar)

-- ALAS-nappi: hypynapin viereen
descendBtn = Instance.new("TextButton")
descendBtn.Name = "DownButton"
descendBtn.Size = UDim2.new(0, 74, 0, 74)
descendBtn.Position = UDim2.new(1, -184, 1, -164)
descendBtn.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
descendBtn.BackgroundTransparency = 0.35
descendBtn.Font = Enum.Font.GothamBold
descendBtn.TextSize = 13
descendBtn.TextColor3 = COLORS.accent
descendBtn.Text = "v\nDESCEND"
descendBtn.BorderSizePixel = 0
descendBtn.Visible = false
descendBtn.Parent = gui
roundify(descendBtn, 16)
strokeify(descendBtn, 0.7, COLORS.accent)
gradientify(descendBtn, Color3.fromRGB(28, 32, 46), Color3.fromRGB(14, 16, 24))

descendBtn.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.downHeld = true
	end
end)
descendBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.downHeld = false
	end
end)

-- RightShift piilottaa / nayttaa valikon
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

gui.Parent = player:WaitForChild("PlayerGui")

--=================== RESPAWN-KASITTELY ======================--
local function onCharacter(c)
	local wasEnabled = state.enabled
	if wasEnabled then
		pcall(disable)
	end
	bindCharacter(c)
	humanoid.Died:Connect(function()
		if state.enabled then
			pcall(disable)
		end
	end)
	if wasEnabled then
		task.wait(0.3)
		enable()
	end
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
