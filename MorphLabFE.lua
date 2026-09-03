--============================================================--
--  MORPH LAB FE (v3) - muuttaa hahmosi ajoneuvoiksi / elaimiksi
--
--  100% FE: ei luoda yhtaan uutta partia, kaikki tehaan oman
--  hahmon raajoille jokaisessa Heartbeat-framessa -> kaikki
--  pelaajat nakevat muodonmuutoksen.
--
--  RIGIT:
--    R6 ensisijainen, R15 varavirta (raajaketjut chain()-apurilla)
--
--  MOODIT:
--    HELI    : runko makuulla, paa=ohjaamo, o.kasi=masto,
--              o.jalka=paapotkuri, v.kasi=hantapuomi,
--              v.jalka=hantapotkuri
--    BUNNY   : kadet=jousitetut korvat, pomppufysiikka
--    DOG     : neljajalkainen, vinottainen rava
--    MONSTER : raskas keinuva hahmo
--
--  OHJAUS:
--    WASD / joystick = ohjaa mihin suuntaan lennetaan
--    ASCEND-nappi / SPACE = nousu
--    DESCEND-nappi / CTRL = lasku
--    SPECIAL-nappi        = moodin erikoisanimaatio
--    X                    = sulje valikko (RightShift avaa)
--    -                    = pienenna valikko
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
	ClimbSpeed     = 18,
	DescendSpeed   = 16,
	Acceleration   = 4,
	ForwardTilt    = 20,
	BankTilt       = 12,
	HoverBob       = 0.7,
	MainRotorIdle  = 8,
	MainRotorMax   = 28,
	MainRotorMin   = 4,
	TailRotorIdle  = 7,
	TailRotorMax   = 28,
	TailRotorGain  = 0.9,
	RotorResponse  = 2.4,
	-- pupu
	BunnySpeed     = 24,
	BunnyHop       = 12,
	BunnyFall      = -6,
	BunnyBigJump   = 15,
	BunnyLean      = 28,
	EarStiffness   = 110,
	EarDamping     = 9,
	EarAccelGain   = 0.0016,
	-- koira
	DogSpeed       = 34,
	DogLeap        = 13,
	-- monsteri
	MonsterSpeed   = 11,
	MonsterSlam    = 10,
	-- maakorkeudet (hrp etaisyys lattiasta laskeutuessa)
	GroundClear = { HELI = 2.2, BUNNY = 2.0, DOG = 2.1, MONSTER = 2.9 },
	-- special kestot
	SpecialDuration = { HELI = 2.4, BUNNY = 1.3, DOG = 2.0, MONSTER = 1.9 },
	-- rajotukset
	MaxSpeed = 90,
}

local MODES = {
	{ id = "HELI",    name = "HELICOPTER", special = "CRASHOUT", up = "ASCEND", down = "DESCEND" },
	{ id = "BUNNY",   name = "BUNNY",      special = "THUMP",    up = "HOP",    down = "DUCK"    },
	{ id = "DOG",     name = "DOG",        special = "BOW",      up = "LEAP",   down = "SIT"     },
	{ id = "MONSTER", name = "MONSTER",    special = "ROAR",     up = "POUND",  down = "CROUCH"  },
}

--======================== TILA ==============================--
local state = {
	enabled     = false,
	mode        = "HELI",
	special     = false,
	specialT    = 0,
	elapsed     = 0,
	rotorAngle  = 0,
	tailAngle   = 0,
	mainSpeed   = CFG.MainRotorIdle,
	tailSpeed   = CFG.TailRotorIdle,
	velocity    = Vector3.zero,
	look        = Vector3.new(0, 0, -1),
	upHeld      = false,
	downHeld    = false,
	thumpPulse  = 0,
	hopPhase    = 0,
	liftPos     = 0,
	earAngle    = 0,
	earVel      = 0,
	prevVy      = 0,
	squash      = 0,
	gaitPhase   = 0,
}

local isR15 = false
local P = {} -- hrp, torso, head, armR/armL/legR/legL (R6) tai *Chain-taulukot (R15)
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

local function validCF(cf)
	local p = cf.Position
	return p.X == p.X and p.Y == p.Y and p.Z == p.Z
		and math.abs(p.X) < 1e5 and math.abs(p.Y) < 1e5 and math.abs(p.Z) < 1e5
end

-- frame jonka -Y osoittaa suuntaan dir (ketjut ja raajalaatikot
-- asettuvat taman mukaan pitkittaisakselilleen)
local function dirFrame(pos, dir)
	if math.abs(dir.Y) > 0.999 then
		dir = (dir + Vector3.new(1e-3, 0, 0)).Unit
	end
	return CFrame.lookAt(pos, pos + dir) * CFrame.Angles(math.rad(90), 0, 0)
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
local ascendBtn
local descendBtn
local specialBtn
local statusLabel

local function modeInfo()
	for _, m in ipairs(MODES) do
		if m.id == state.mode then return m end
	end
	return MODES[1]
end

local function destroyMovers()
	if bodyVelocity then pcall(function() bodyVelocity:Destroy() end); bodyVelocity = nil end
	if bodyGyro then pcall(function() bodyGyro:Destroy() end); bodyGyro = nil end
end

local function enable()
	if state.enabled then return end
	if not humanoid or humanoid.Parent == nil then return end

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
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	setBodyCollisions(false)

	-- nollaa likemaara ettei hahmo singahda
	pcall(function()
		P.hrp.AssemblyLinearVelocity = Vector3.zero
		P.hrp.AssemblyAngularVelocity = Vector3.zero
	end)

	-- tuhoa vanhat liikuttimet ennen uusia (ei koskaan kahta)
	destroyMovers()

	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(5e5, 5e5, 5e5)
	bodyVelocity.Velocity = Vector3.zero
	bodyVelocity.Parent = P.hrp

	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(4e5, 4e5, 4e5)
	bodyGyro.P = 2e4
	bodyGyro.D = 1000
	bodyGyro.CFrame = P.hrp.CFrame
	bodyGyro.Parent = P.hrp

	if ascendBtn then
		ascendBtn.Visible = true
		ascendBtn.Text = "^\n" .. modeInfo().up
	end
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
	state.upHeld = false
	state.downHeld = false

	destroyMovers()

	if humanoid and humanoid.Parent then
		pcall(function()
			P.hrp.AssemblyLinearVelocity = Vector3.zero
			P.hrp.AssemblyAngularVelocity = Vector3.zero
		end)
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
		setBodyCollisions(false)
	end

	if animateScript then animateScript.Disabled = false end
	stopAnimations()

	if ascendBtn then ascendBtn.Visible = false end
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
-- Suuntavektoreihin perustuva asettelu: jokaiselle raajalle
-- lasketaan keskipiste ja suunta, ja dirFrame asettaa osan
-- pitkittaisakselin (Y) siihen. R15-ketjut jatkavat samasta
-- pisteesta chain()-apurilla.

local function poseHeli(base, t)
	local crash = state.special

	-- base-frame helissa: +Y = nokka, -Y = hanta, +Z = ylos, +X = oikea
	local noseW  = base:VectorToWorldSpace(Vector3.new(0, 1, 0))
	local upW    = base:VectorToWorldSpace(Vector3.new(0, 0, 1))
	local tailW  = -noseW

	local torsoCF = base
	if crash then torsoCF = torsoCF * shakeCF(0.1, 0.09) end

	if isR15 then
		P.torso.CFrame = torsoCF
		P.lowerTorso.CFrame = base * CFrame.new(0, -0.55, 0.05)
	else
		P.torso.CFrame = torsoCF
	end

	-- paa = ohjaamo (katsoo kohti nokkaa; crashissa taakse ja ylos)
	local headPos
	if crash then
		headPos = (base * CFrame.new(0, 1.30, 0.55)).Position
		P.head.CFrame = CFrame.lookAt(headPos, headPos + tailW)
			* CFrame.Angles(math.rad(-35) + math.rad(6) * math.sin(t * 16), 0, 0)
			* shakeCF(0.05, 0.08)
	else
		headPos = (base * CFrame.new(0, 1.55, 0.28)).Position
		P.head.CFrame = CFrame.lookAt(headPos, headPos + noseW)
	end

	-- masto: juuri selassa, osoittaa ylos (pieni huojunta)
	local mastRoot = (base * CFrame.new(0, -0.45, 1.05)).Position
	local mastDir = upW
	if not crash then
		mastDir = (upW + noseW * (0.04 * math.sin(t * 2.3))).Unit
	end

	-- paapotkuri: maston paassa, lapa pyorii XY-tasossa (base)
	local mastTip = mastRoot + mastDir * 2.1
	local bladeDir = (noseW * math.cos(state.rotorAngle)
		+ base:VectorToWorldSpace(Vector3.new(1, 0, 0)) * math.sin(state.rotorAngle))

	-- hanta: juuri takana, osoittaa taakse
	local boomRoot = (base * CFrame.new(0, -1.05, 0.3)).Position
	local boomDir = tailW
	if crash then
		boomDir = (tailW + upW * -0.35).Unit
	end

	-- hantapotkuri: puomissa, lapa pyorii XZ-tasossa (base)
	local boomTip = boomRoot + boomDir * 2.1
	local tailBladeDir = (base:VectorToWorldSpace(Vector3.new(1, 0, 0)) * math.cos(state.tailAngle)
		+ upW * math.sin(state.tailAngle))

	if isR15 then
		-- o.kaden ketju = masto
		local mastBase = dirFrame(mastRoot, mastDir)
		if crash then
			mastBase = dirFrame(mastRoot, (upW * -0.9 + tailW * 0.4).Unit)
		end
		local mastEnd = chain(mastBase, P.armRChain)
		mastTip = (mastEnd * CFrame.new(0, -0.5, 0)).Position

		-- o.jalan ketju = paapotkurin lapa
		chain(dirFrame(mastTip, bladeDir), P.legRChain)

		-- v.kaden ketju = hantapuomi
		local boomEnd = chain(dirFrame(boomRoot, boomDir), P.armLChain)
		boomTip = (boomEnd * CFrame.new(0, -0.5, 0)).Position

		-- v.jalan ketju = hantapotkurin lapa
		chain(dirFrame(boomTip, tailBladeDir), P.legLChain)
	else
		-- o.kasi = masto (keskipiste = juuri + 1.0 suuntaan)
		local mastCenter = mastRoot + mastDir * 1.0
		if crash then
			mastCenter = mastRoot + (upW * -0.9 + tailW * 0.4).Unit * 1.0
			P.armR.CFrame = dirFrame(mastCenter, (upW * -0.9 + tailW * 0.4).Unit)
		else
			P.armR.CFrame = dirFrame(mastCenter, mastDir)
		end

		-- o.jalka = paapotkuri
		P.legR.CFrame = dirFrame(mastTip, bladeDir)

		-- v.kasi = hantapuomi
		P.armL.CFrame = dirFrame(boomRoot + boomDir * 1.0, boomDir)

		-- v.jalka = hantapotkuri
		P.legL.CFrame = dirFrame(boomTip, tailBladeDir)
	end
end

local function poseBunny(base, t)
	local lift = state.liftPos
	local sq = state.squash
	local earBack = 0.22 + state.earAngle
	local twitchY = math.rad(3) * math.sin(t * 1.7) + math.rad(1.5) * math.sin(t * 5.3)
	local headP = math.rad(4) * math.sin(t * 2.9)

	if state.special then -- THUMP
		sq = sq + 0.15 * math.abs(math.sin(state.specialT * 14))
	end

	-- base-frame: +Y = ylos, -Z = eteenpain
	-- korvasuunta: ylos ja hieman taakse (earBack), sivulle vino
	local earDirL = (base:VectorToWorldSpace(
		Vector3.new(-0.14, math.cos(earBack), math.sin(earBack)))).Unit
	local earDirR = (base:VectorToWorldSpace(
		Vector3.new(0.14, math.cos(earBack), math.sin(earBack)))).Unit

	-- jalat: kyykky (taitettu taakse) <-> ojennus (alas)
	local legDirFold = Vector3.new(0, -0.45, 0.89)
	local legDirExt  = Vector3.new(0, -0.95, 0.3)
	local legDirBase = (legDirFold:Lerp(legDirExt, lift)).Unit
	local legDirL = (base:VectorToWorldSpace(legDirBase)).Unit
	local legDirR = legDirL

	if isR15 then
		P.lowerTorso.CFrame = base * CFrame.new(0, -sq, 0)
		P.torso.CFrame = base * CFrame.new(0, 0.55 - sq, -0.02)
		P.head.CFrame = base * CFrame.new(0, 1.32 - sq, -0.08)
			* CFrame.Angles(headP, twitchY, 0)

		local earRootL = (base * CFrame.new(-0.28, 1.18 - sq, 0.12)).Position
		local earRootR = (base * CFrame.new(0.28, 1.18 - sq, 0.12)).Position
		chain(dirFrame(earRootL, earDirL), P.armLChain)
		chain(dirFrame(earRootR, earDirR), P.armRChain)

		local hipL = (base * CFrame.new(-0.42, -0.55 - sq, 0.05)).Position
		local hipR = (base * CFrame.new(0.42, -0.55 - sq, 0.05)).Position
		chain(dirFrame(hipL, legDirL), P.legLChain)
		chain(dirFrame(hipR, legDirR), P.legRChain)
	else
		P.torso.CFrame = base * CFrame.new(0, -sq, 0)
		P.head.CFrame = base * CFrame.new(0, 1.5 - sq, -0.08)
			* CFrame.Angles(headP, twitchY, 0)

		-- korvat
		local earCenterL = (base * CFrame.new(-0.32, 1.05 - sq, 0.12)).Position + earDirL * 1.0
		local earCenterR = (base * CFrame.new(0.32, 1.05 - sq, 0.12)).Position + earDirR * 1.0
		P.armL.CFrame = dirFrame(earCenterL, earDirL)
		P.armR.CFrame = dirFrame(earCenterR, earDirR)

		-- jalat
		local legCenterL = (base * CFrame.new(-0.5, -0.62 - sq, 0.08)).Position + legDirL * 1.0
		local legCenterR = (base * CFrame.new(0.5, -0.62 - sq, 0.08)).Position + legDirR * 1.0
		P.legL.CFrame = dirFrame(legCenterL, legDirL)
		P.legR.CFrame = dirFrame(legCenterR, legDirR)
	end
end

local function poseDog(base, t)
	local g = state.gaitPhase * math.pi * 2
	local swing = math.sin(g) * 0.55
	local pant = math.rad(5) * math.sin(t * 6)
	local bow = state.special

	-- base-frame: +Y = nokka, +Z = ylos
	local noseW = base:VectorToWorldSpace(Vector3.new(0, 1, 0))

	-- jalkojen suunta: alas + keinu eteen/taakse (vinottainen ravi)
	local function legDir(s)
		return (base:VectorToWorldSpace(Vector3.new(0, s, -1))).Unit
	end

	local frontSwingR, frontSwingL = swing, -swing
	local backSwingR, backSwingL = -swing, swing
	if bow then
		frontSwingR, frontSwingL = 0.9, 0.9 -- etujalat suoraksi eteen
		backSwingR = 0.2 * math.sin(t * 14)
		backSwingL = 0.2 * math.sin(t * 14 + 1)
		pant = math.rad(18)
	end

	-- paa: nokkason suuntaan, hengitys
	local headPos = (base * CFrame.new(0, 1.15, 0.3)).Position
	P.head.CFrame = CFrame.lookAt(headPos, headPos + noseW)
		* CFrame.Angles(pant, math.rad(4) * math.sin(t * 2.2), 0)

	if isR15 then
		P.lowerTorso.CFrame = base * CFrame.new(0, -0.5, 0.05)
		P.torso.CFrame = base * CFrame.new(0, 0.55, 0.02)

		local shL = (base * CFrame.new(-0.5, 0.62, -0.25)).Position
		local shR = (base * CFrame.new(0.5, 0.62, -0.25)).Position
		local hipL = (base * CFrame.new(-0.5, -0.55, -0.25)).Position
		local hipR = (base * CFrame.new(0.5, -0.55, -0.25)).Position
		chain(dirFrame(shL, legDir(frontSwingL)), P.armLChain)
		chain(dirFrame(shR, legDir(frontSwingR)), P.armRChain)
		chain(dirFrame(hipL, legDir(backSwingL)), P.legLChain)
		chain(dirFrame(hipR, legDir(backSwingR)), P.legRChain)
	else
		P.torso.CFrame = base

		-- etujalat (kadet) ja takajalat, vinottain vastavaheessa
		P.armR.CFrame = dirFrame(
			(base * CFrame.new(0.55, 0.72, -0.25)).Position + legDir(frontSwingR) * 1.0,
			legDir(frontSwingR))
		P.armL.CFrame = dirFrame(
			(base * CFrame.new(-0.55, 0.72, -0.25)).Position + legDir(frontSwingL) * 1.0,
			legDir(frontSwingL))
		P.legR.CFrame = dirFrame(
			(base * CFrame.new(0.5, -0.72, -0.25)).Position + legDir(backSwingR) * 1.0,
			legDir(backSwingR))
		P.legL.CFrame = dirFrame(
			(base * CFrame.new(-0.5, -0.72, -0.25)).Position + legDir(backSwingL) * 1.0,
			legDir(backSwingL))
	end
end

local function poseMonster(base, t)
	local g = state.gaitPhase * math.pi * 2
	local sway = math.rad(4) * math.sin(t * 1.4)
	local armSwing = math.sin(g) * 0.22
	local legSwing = math.sin(g) * 0.18
	local roar = state.special

	-- base-frame: +Y = ylos, -Z = eteen
	if isR15 then
		P.lowerTorso.CFrame = base
		P.torso.CFrame = base * CFrame.new(0, 0.55, -0.04)
			* CFrame.Angles(math.rad(8), sway, 0)

		if roar then
			P.head.CFrame = base * CFrame.new(0, 1.5, 0.05)
				* CFrame.Angles(math.rad(-38) + math.rad(5) * math.sin(t * 20), 0, 0)
				* shakeCF(0.05, 0.06)
			local upDirL = (base:VectorToWorldSpace(Vector3.new(-0.25, 1, 0.15))).Unit
			local upDirR = (base:VectorToWorldSpace(Vector3.new(0.25, 1, 0.15))).Unit
			chain(dirFrame((base * CFrame.new(-0.85, 0.85, -0.05)).Position, upDirL), P.armLChain)
			chain(dirFrame((base * CFrame.new(0.85, 0.85, -0.05)).Position, upDirR), P.armRChain)
		else
			P.head.CFrame = base * CFrame.new(0, 1.48, -0.3)
				* CFrame.Angles(math.rad(24), sway, 0)
			-- kadet lysahtaneina eteen-alas
			local armDirL = (base:VectorToWorldSpace(Vector3.new(-0.12, -0.5, -0.85 - armSwing))).Unit
			local armDirR = (base:VectorToWorldSpace(Vector3.new(0.12, -0.5, -0.85 + armSwing))).Unit
			chain(dirFrame((base * CFrame.new(-0.85, 0.85, -0.08)).Position, armDirL), P.armLChain)
			chain(dirFrame((base * CFrame.new(0.85, 0.85, -0.08)).Position, armDirR), P.armRChain)
		end

		local legDirL = (base:VectorToWorldSpace(Vector3.new(0, -1, legSwing))).Unit
		local legDirR = (base:VectorToWorldSpace(Vector3.new(0, -1, -legSwing))).Unit
		chain(dirFrame((base * CFrame.new(-0.45, -0.5, 0)).Position, legDirL), P.legLChain)
		chain(dirFrame((base * CFrame.new(0.45, -0.5, 0)).Position, legDirR), P.legRChain)
	else
		P.torso.CFrame = base * CFrame.Angles(0, sway, 0)

		if roar then
			P.head.CFrame = base * CFrame.new(0, 1.5, 0.1)
				* CFrame.Angles(math.rad(-40) + math.rad(5) * math.sin(t * 20), 0, 0)
				* shakeCF(0.05, 0.06)
			local upDirL = (base:VectorToWorldSpace(Vector3.new(-0.25, 1, 0.15))).Unit
			local upDirR = (base:VectorToWorldSpace(Vector3.new(0.25, 1, 0.15))).Unit
			P.armL.CFrame = dirFrame(
				(base * CFrame.new(-0.8, 0.6, 0)).Position + upDirL * 1.0, upDirL)
			P.armR.CFrame = dirFrame(
				(base * CFrame.new(0.8, 0.6, 0)).Position + upDirR * 1.0, upDirR)
		else
			P.head.CFrame = base * CFrame.new(0, 1.45, -0.28)
				* CFrame.Angles(math.rad(22), sway, 0)
			local armDirL = (base:VectorToWorldSpace(Vector3.new(-0.12, -0.5, -0.85 - armSwing))).Unit
			local armDirR = (base:VectorToWorldSpace(Vector3.new(0.12, -0.5, -0.85 + armSwing))).Unit
			P.armL.CFrame = dirFrame(
				(base * CFrame.new(-0.8, 0.5, -0.05)).Position + armDirL * 1.0, armDirL)
			P.armR.CFrame = dirFrame(
				(base * CFrame.new(0.8, 0.5, -0.05)).Position + armDirR * 1.0, armDirR)
		end

		local legDirL = (base:VectorToWorldSpace(Vector3.new(0, -1, legSwing))).Unit
		local legDirR = (base:VectorToWorldSpace(Vector3.new(0, -1, -legSwing))).Unit
		P.legL.CFrame = dirFrame(
			(base * CFrame.new(-0.5, -0.95, 0)).Position + legDirL * 1.0, legDirL)
		P.legR.CFrame = dirFrame(
			(base * CFrame.new(0.5, -0.95, 0)).Position + legDirR * 1.0, legDirR)
	end
end

--============================================================--
--                       PAALUUPPI
--============================================================--
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.Heartbeat:Connect(function(dt)
	if not state.enabled then return end
	if not P.hrp or P.hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end
	if not bodyVelocity or bodyVelocity.Parent == nil then return end

	local base = P.hrp.CFrame
	if not validCF(base) then
		disable()
		return
	end

	state.elapsed = state.elapsed + dt
	local t = state.elapsed

	stopAnimations()
	if humanoid.Sit then humanoid.Sit = false end

	-- suunta kamerasta (tasoitettu)
	local cam = workspace.CurrentCamera
	local camLook = cam and cam.CFrame.LookVector or base.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude > 1e-3 then
		flatLook = flatLook.Unit
		state.look = dampV3(state.look, flatLook, 6, dt)
	end
	local look = state.look
	if look.Magnitude < 1e-3 then look = flatLook end
	look = look.Unit
	local right = look:Cross(Vector3.yAxis)

	-- input: WASD/joystick + napit
	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	local upInput = state.upHeld or humanoid.Jump
		or UserInputService:IsKeyDown(Enum.KeyCode.Space)
	local downInput = state.downHeld
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)

	-- lattia-raycast: esta lapi uppoaminen
	rayParams.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(P.hrp.Position, Vector3.new(0, -60, 0), rayParams)
	local floorY = hit and hit.Position.Y or nil
	local clearance = CFG.GroundClear[state.mode] or 2.2

	local desired
	local gyroCF

	if state.mode == "HELI" then
		---------------- HELIKOPTERI ----------------
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
			vertical = vertical + (rng:NextNumber() - 0.5) * 8
		end
		desired = flat * spd + Vector3.new(0, vertical, 0)

		local fSpeed = state.velocity:Dot(look)
		local sSpeed = state.velocity:Dot(right)
		local pitchExtra = -math.rad(CFG.ForwardTilt) * math.clamp(fSpeed / CFG.ForwardSpeed, -1, 1)
		local roll = -math.rad(CFG.BankTilt) * math.clamp(sSpeed / CFG.ForwardSpeed, -1, 1)

		local jx, jy, jz = 0, 0, 0
		if state.special then
			jx = (rng:NextNumber() - 0.5) * math.rad(8)
			jy = (rng:NextNumber() - 0.5) * math.rad(8)
			jz = (rng:NextNumber() - 0.5) * math.rad(8)
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
		if state.special then mainTarget = 4 + 8 * math.abs(math.sin(t * 6.5)) end
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
		---------------- PUPU ----------------
		local hSpeed = downInput and 0 or CFG.BunnySpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		if spd > 1 then
			state.hopPhase = (state.hopPhase + dt * (1.5 + spd / 12)) % 1
		else
			state.hopPhase = (state.hopPhase + dt * 0.8) % 1
		end

		local s = math.sin(state.hopPhase * math.pi * 2)
		state.liftPos = math.clamp(s, 0, 1)
		local vy
		if downInput then
			vy = 0
		elseif spd > 1 or upInput then
			vy = s > 0 and (s ^ 1.3) * CFG.BunnyHop or CFG.BunnyFall
		else
			vy = math.sin(t * 3.2) * 0.6
		end
		if upInput then
			vy = math.max(vy, CFG.BunnyBigJump)
		end
		if state.thumpPulse > 0 then
			vy = math.max(vy, state.thumpPulse)
			state.thumpPulse = math.max(0, state.thumpPulse - dt * 40)
		end

		-- korvajousi
		local acc = math.clamp((vy - state.prevVy) / math.max(dt, 1e-4), -220, 220)
		state.prevVy = vy
		state.earVel = state.earVel
			+ (-CFG.EarStiffness * state.earAngle - CFG.EarDamping * state.earVel) * dt
			+ acc * CFG.EarAccelGain
		state.earAngle = math.clamp(state.earAngle + state.earVel * dt, -0.5, 0.85)

		local targetSquash = (s < 0 and spd > 1) and 0.16 or 0
		if state.special then targetSquash = targetSquash + 0.1 end
		state.squash = damp(state.squash, targetSquash, 14, dt)

		desired = horizV + Vector3.new(0, vy, 0)

		local lean = math.rad(CFG.BunnyLean) * math.clamp(spd / CFG.BunnySpeed, 0, 1)
		if downInput then lean = math.rad(12) end
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(-lean, 0, 0)

	elseif state.mode == "DOG" then
		---------------- KOIRA ----------------
		local hSpeed = downInput and 0 or CFG.DogSpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		if spd > 1 then
			state.gaitPhase = (state.gaitPhase + dt * (1.6 + spd / 9)) % 1
		end
		local trot = math.abs(math.sin(state.gaitPhase * math.pi * 2))
		local vy = spd > 1 and (trot * 2.2 - 1.1) or math.sin(t * 2.5) * 0.4
		if upInput then vy = math.max(vy, CFG.DogLeap) end
		if downInput then vy = 0 end

		desired = horizV + Vector3.new(0, vy, 0)

		local pitch = math.rad(-78)
		if downInput then pitch = math.rad(-42) end
		if state.special then pitch = math.rad(-96) end
		local sway = math.rad(3) * math.sin(t * 2)
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(pitch, 0, sway)

	else
		---------------- MONSTERI ----------------
		local hSpeed = downInput and CFG.MonsterSpeed * 0.4 or CFG.MonsterSpeed
		local horizV = flat * hSpeed
		local spd = horizV.Magnitude

		if spd > 1 then
			state.gaitPhase = (state.gaitPhase + dt * (1.1 + spd / 10)) % 1
		end
		local stomp = math.abs(math.sin(state.gaitPhase * math.pi * 2))
		local vy = spd > 1 and (stomp * 1.5 - 0.75) or math.sin(t * 1.8) * 0.4
		if upInput then vy = math.max(vy, CFG.MonsterSlam) end
		if state.special then
			vy = vy + math.sin(t * 22) * 1.1
		end

		desired = horizV + Vector3.new(0, vy, 0)

		local lean = math.rad(-24)
		if downInput then lean = math.rad(-38) end
		local sway = math.rad(4) * math.sin(t * 1.4)
		local pos = P.hrp.Position
		gyroCF = CFrame.lookAt(pos, pos + look) * CFrame.Angles(lean, 0, sway)
	end

	-- lattiaklampi: ei lapi maasta
	if floorY then
		local heightAbove = P.hrp.Position.Y - floorY
		if heightAbove < clearance + 0.2 and desired.Y < 0 then
			desired = Vector3.new(desired.X, 0, desired.Z)
		end
	end

	-- nopeuden pehmennys ja rajoitus
	state.velocity = dampV3(state.velocity, desired, CFG.Acceleration, dt)
	if state.velocity.Magnitude > CFG.MaxSpeed then
		state.velocity = state.velocity.Unit * CFG.MaxSpeed
	end

	bodyVelocity.Velocity = state.velocity
	if validCF(gyroCF) then
		bodyGyro.CFrame = gyroCF
	end

	-- special-ajastin
	if state.special then
		state.specialT = state.specialT + dt
		if state.specialT >= (CFG.SpecialDuration[state.mode] or 2) then
			state.special = false
		end
	end

	-- pose (luetaan base uudestaan, hrp on voinut liikkua)
	base = P.hrp.CFrame
	if not validCF(base) then return end

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

local function gradientify(obj, topColor, bottomColor)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	g.Rotation = 90
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
main.Size = UDim2.new(0, 264, 0, 272)
main.Position = UDim2.new(0, 24, 0.5, -136)
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
title.Size = UDim2.new(1, -100, 1, 0)
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
minBtn.Position = UDim2.new(1, -62, 0.5, -12)
minBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
minBtn.BackgroundTransparency = 0.9
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 15
minBtn.TextColor3 = COLORS.text
minBtn.Text = "-"
minBtn.BorderSizePixel = 0
minBtn.Parent = titleBar
roundify(minBtn, 8)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -32, 0.5, -12)
closeBtn.BackgroundColor3 = COLORS.red
closeBtn.BackgroundTransparency = 0.55
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 13
closeBtn.TextColor3 = COLORS.text
closeBtn.Text = "X"
closeBtn.BorderSizePixel = 0
closeBtn.Parent = titleBar
roundify(closeBtn, 8)

-- sisalto
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, 0, 1, -38)
content.Position = UDim2.new(0, 0, 0, 38)
content.BackgroundTransparency = 1
content.Parent = main

-- moodipillit
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
		if ascendBtn then ascendBtn.Text = "^\n" .. modeInfo().up end
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

local effectCaption = Instance.new("TextLabel")
effectCaption.Size = UDim2.new(1, -24, 0, 14)
effectCaption.Position = UDim2.new(0, 12, 0, 114)
effectCaption.BackgroundTransparency = 1
effectCaption.Font = Enum.Font.Gotham
effectCaption.TextSize = 9
effectCaption.TextColor3 = COLORS.textDim
effectCaption.TextXAlignment = Enum.TextXAlignment.Left
effectCaption.Text = "SPECIAL EFFECT"
effectCaption.Parent = content

specialBtn = makeButton(modeInfo().special, COLORS.orange, 128, 38)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -24, 0, 52)
hint.Position = UDim2.new(0, 12, 0, 172)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextColor3 = COLORS.textDim
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.TextYAlignment = Enum.TextYAlignment.Top
hint.Text = "WASD / joystick = steer\n"
	.. "SPACE / ASCEND = up    CTRL / DESCEND = down\n"
	.. "RightShift = reopen closed panel"
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

-- sulku: piilottaa koko valikon, RightShift avaa uudelleen
closeBtn.MouseButton1Click:Connect(function()
	gui.Enabled = false
end)

makeDraggable(main, titleBar)

-- ilmavaivat napit: ASCEND ja DESCEND hypynapin viereen
local function makeFloatBtn(name, xOffset)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.new(0, 74, 0, 74)
	b.Position = UDim2.new(1, xOffset, 1, -164)
	b.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
	b.BackgroundTransparency = 0.35
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = COLORS.accent
	b.BorderSizePixel = 0
	b.Visible = false
	b.Parent = gui
	roundify(b, 16)
	strokeify(b, 0.7, COLORS.accent)
	gradientify(b, Color3.fromRGB(28, 32, 46), Color3.fromRGB(14, 16, 24))
	return b
end

ascendBtn = makeFloatBtn("AscendButton", -264)
ascendBtn.Text = "^\nASCEND"
descendBtn = makeFloatBtn("DescendButton", -180)
descendBtn.Text = "v\nDESCEND"

ascendBtn.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.upHeld = true
	end
end)
ascendBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.upHeld = false
	end
end)
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

-- RightShift avaa/sulkee valikon
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
