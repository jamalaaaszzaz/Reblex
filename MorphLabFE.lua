--============================================================--
--  MORPH LAB FE (v4) - muuttaa hahmosi ajoneuvoiksi / elaimiksi
--
--  100% FE: ei luoda yhtaan uutta partia.
--
--  TEKNIIKKA (sama jolla Robloxin animaatiot toimivat):
--    1. Motor6D-liitosten C0-arvot asetetaan poseen. Luajan
--       omistamat liitokset replikoituvat -> KAIKKI pelaajat
--       nakevat muodonmuutoksen ilman etta osia kosketaan.
--    2. Fysiikan solveri itse asettaa osat liitosten mukaan
--       -> ei fysiikkataistelua, ei flingia, ei sekoilua.
--    3. Lentoon vain BodyVelocity + BodyGyro (vain yaw, kuten
--       toimivassa FE-drone-referenssissa). Rungon kallistus
--       tehdaan myos liitoksen kautta, ei gyron kautta.
--
--  RIGIT: R6 ensisijainen, R15 varavirta.
--
--  OHJAUS:
--    WASD / joystick = ohjaa suuntaa (leijuu paikallaan)
--    ASCEND-nappi / SPACE = nousu
--    DESCEND-nappi / CTRL = lasku
--    SPECIAL = moodin erikoisanimaatio
--    - = pienenna, X = sulje, RightShift = avaa uudelleen
--============================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

--====================== ASETUKSET ===========================--
local CFG = {
	ForwardSpeed   = 30,
	BackwardSpeed  = 14,
	ClimbSpeed     = 18,
	DescendSpeed   = 16,
	Acceleration   = 4,
	ForwardTilt    = 20,    -- astetta, nokka alas kiihdyttaessa
	BankTilt       = 12,    -- astetta, sivuttaisliikkeen kallistus
	HoverBob       = 0.6,
	MainRotorIdle  = 8,
	MainRotorMax   = 28,
	MainRotorMin   = 4,
	TailRotorIdle  = 7,
	TailRotorMax   = 28,
	TailRotorGain  = 0.9,
	RotorResponse  = 2.4,
	BunnySpeed     = 24,
	BunnyHop       = 12,
	BunnyFall      = -6,
	BunnyBigJump   = 15,
	BunnyLean      = 26,
	EarStiffness   = 110,
	EarDamping     = 9,
	EarAccelGain   = 0.0016,
	DogSpeed       = 34,
	DogLeap        = 13,
	MonsterSpeed   = 11,
	MonsterSlam    = 10,
	GroundClear    = { HELI = 2.2, BUNNY = 2.0, DOG = 2.1, MONSTER = 2.9 },
	SpecialDuration = { HELI = 2.4, BUNNY = 1.3, DOG = 2.0, MONSTER = 1.9 },
	MaxSpeed       = 90,
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
local char, humanoid, hrp, animator, animateScript
local bodyVelocity, bodyGyro
local rng = Random.new()

local J = {}      -- liitokset: root, neck, shoulderR/L, hipR/L (+ r15: waist, wristit, nilkat)
local orig = {}   -- original C0/C1: [motor] = {c0=..., c1=...}
local resetCF = {} -- [motor] = CFrame.new(0,0,0)

--====================== APURIT ==============================--
local function damp(a, b, k, dt)
	return a + (b - a) * (1 - math.exp(-k * dt))
end

local function dampV3(a, b, k, dt)
	return a:Lerp(b, 1 - math.exp(-k * dt))
end

local function addWobble(cf, posMag, rotMag)
	return cf * CFrame.new(
		(rng:NextNumber() - 0.5) * 2 * posMag,
		(rng:NextNumber() - 0.5) * 2 * posMag,
		(rng:NextNumber() - 0.5) * 2 * posMag
	) * CFrame.Angles(
		(rng:NextNumber() - 0.5) * 2 * rotMag,
		(rng:NextNumber() - 0.5) * 2 * rotMag,
		(rng:NextNumber() - 0.5) * 2 * rotMag
	)
end

local function stopAnimations()
	if not animator then return end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
	end
end

--====================== RIGIN SITOminen =====================--
local function bindCharacter(c)
	char = c
	humanoid = c:WaitForChild("Humanoid")
	hrp = c:WaitForChild("HumanoidRootPart")
	isR15 = humanoid.RigType == Enum.HumanoidRigType.R15

	J = {}
	orig = {}
	resetCF = {}

	local function grab(motor, key)
		orig[motor] = { c0 = motor.C0, c1 = motor.C1 }
		resetCF[motor] = CFrame.new(0, 0, 0)
		J[key] = motor
	end

	if isR15 then
		local lower = c:WaitForChild("LowerTorso")
		local upper = c:WaitForChild("UpperTorso")
		grab(hrp:WaitForChild("RootJoint"), "root")
		grab(lower:WaitForChild("Root"), "waist")
		grab(upper:WaitForChild("Neck"), "neck")
		grab(upper:WaitForChild("RightShoulder"), "shoulderR")
		grab(upper:WaitForChild("LeftShoulder"), "shoulderL")
		grab(lower:WaitForChild("RightHip"), "hipR")
		grab(lower:WaitForChild("LeftHip"), "hipL")
		-- ketjun loppuosat: pidetaan suorina (identity C0 = kyynarpaat
		-- ja nilkat ojennuksessa, ei kosketa koskaan)
		local armR = c:WaitForChild("RightUpperArm")
		local armL = c:WaitForChild("LeftUpperArm")
		local armRLow = c:WaitForChild("RightLowerArm")
		local armLLow = c:WaitForChild("LeftLowerArm")
		local legR = c:WaitForChild("RightUpperLeg")
		local legL = c:WaitForChild("LeftUpperLeg")
		local legRLow = c:WaitForChild("RightLowerLeg")
		local legLLow = c:WaitForChild("LeftLowerLeg")
		grab(armR:WaitForChild("RightElbow"), "elbowR")
		grab(armL:WaitForChild("LeftElbow"), "elbowL")
		grab(armRLow:WaitForChild("RightWrist"), "wristR")
		grab(armLLow:WaitForChild("LeftWrist"), "wristL")
		grab(legR:WaitForChild("RightKnee"), "kneeR")
		grab(legL:WaitForChild("LeftKnee"), "kneeL")
		grab(legRLow:WaitForChild("RightAnkle"), "ankleR")
		grab(legLLow:WaitForChild("LeftAnkle"), "ankleL")
	else
		local torso = c:WaitForChild("Torso")
		grab(torso:WaitForChild("RootJoint"), "root")
		grab(torso:WaitForChild("Neck"), "neck")
		grab(torso:WaitForChild("Right Shoulder"), "shoulderR")
		grab(torso:WaitForChild("Left Shoulder"), "shoulderL")
		grab(torso:WaitForChild("Right Hip"), "hipR")
		grab(torso:WaitForChild("Left Hip"), "hipL")
	end

	animator = humanoid:WaitForChild("Animator")
	animateScript = c:FindFirstChild("Animate")
end

-- palauttaa kaikki liitokset ja fysiikan normaaliksi
local function restoreJoints()
	for motor, o in pairs(orig) do
		if motor and motor.Parent then
			pcall(function()
				motor.C0 = o.c0
				motor.C1 = o.c1
			end)
		end
	end
end

local function resetAllC0()
	for motor, id in pairs(resetCF) do
		if motor and motor.Parent then
			pcall(function() motor.C0 = id end)
		end
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

	-- VAIHE 1: pysayta pelin animaatiot ensin
	if animateScript then animateScript.Disabled = true end
	stopAnimations()

	-- VAIHE 2: fysiikkaa ajetaan BodyVelocitylla/Gyrolla (yaw-only,
	-- sama kaava kuin toimivassa FE-drone-referenssissa)
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false

	pcall(function()
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end)

	destroyMovers()

	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.Velocity = Vector3.zero
	bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bodyVelocity.Parent = hrp

	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	bodyGyro.P = 9000
	bodyGyro.CFrame = CFrame.new(hrp.Position,
		hrp.Position + Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z))
	bodyGyro.Parent = hrp

	-- VAIHE 3: jointit nollataan ensin; pose otetaan kayttoon
	-- seuraavassa framessa (render-loopissa) -> ei fysiikan pomppua
	resetAllC0()

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
	restoreJoints()

	if humanoid and humanoid.Parent then
		pcall(function()
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end)
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
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
--                 POSET (Motor6D C0-arvot)
--============================================================--
-- Kaikki C0-arvot ovat liitoksen Part0-koordinaatistossa.
-- Liitoksen oletusasento (identity) = liitos pisteeseen
-- (0, -1, 0) liittyvan raajan kohdalla oleva osa osoittaa
-- "suorana alaspain" hahmon katsoessa eteenpain.
-- Taitekaava yleisesti: part1-cf = part0cf * C0 * (C1 inverssi)
-- joten C0 maarittaa suoran offsetin + kaannon.

local function poseHeli(t)
	local crash = state.special
	local bob = math.sin(t * 2.3)

	-- root: runko makuulle. -90 X-kaannos: hahmo vaakatasoon,
	-- paa kohti katsesuntaa. + pieni kallistus nopeudesta.
	local fwd = math.clamp(state.velocity.Magnitude / CFG.ForwardSpeed, 0, 1)
	local tilt = math.rad(CFG.ForwardTilt) * fwd
	local rootCF = CFrame.new(0, -0.2, 0) * CFrame.Angles(math.rad(-90) + tilt, 0, 0)
	if crash then
		rootCF = addWobble(rootCF, 0.06, 0.05)
	end
	J.root.C0 = rootCF

	if isR15 then
		J.waist.C0 = CFrame.new(0, 0, 0) -- vartalo suorana
	end

	-- paa = ohjaamo: kaula taitettuna niin etta paa osoittaa eteen
	if crash then
		J.neck.C0 = CFrame.new(0, 0, 0)
			* CFrame.Angles(math.rad(-25) + math.rad(5) * math.sin(t * 16), 0, 0)
		J.neck.C0 = addWobble(J.neck.C0, 0.03, 0.05)
	else
		J.neck.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(78), 0, 0)
	end

	-- o.kasi = masto selasta ylos: olkapaa rungon ylareunaan (0.5, 0.5, 0)
	-- ja kasi osoittaa rungon "ylospain"-suuntaan (taakse makuuasennossa)
	if crash then
		J.shoulderR.C0 = CFrame.new(0.5, 0.5, 0)
			* CFrame.Angles(math.rad(140), 0, math.rad(90))
	else
		J.shoulderR.C0 = CFrame.new(0.5, 0.5, 0)
			* CFrame.Angles(math.rad(90) + math.rad(2.5) * bob, 0, math.rad(90))
	end

	-- o.jalka = paapotkuri: asennettu maston paahan.
	-- maston pituus 2 (kasi), joten lapa on 2.1 ylapuolella.
	-- pyorii Z-akselin ympari rungon ylatasossa.
	local bladeCF = CFrame.new(0.5, 0.5, 2.15)
		* CFrame.Angles(0, state.rotorAngle, math.rad(90))
	if crash then
		bladeCF = CFrame.new(0.5, 0.7, -1.0)
			* CFrame.Angles(0, state.rotorAngle, math.rad(90))
	end
	J.hipR.C0 = bladeCF

	-- v.kasi = hantapuomi: rungon alareunasta taaksepain
	if crash then
		J.shoulderL.C0 = CFrame.new(-0.5, -0.5, 0)
			* CFrame.Angles(math.rad(-35), 0, math.rad(90))
	else
		J.shoulderL.C0 = CFrame.new(-0.5, -0.5, 0)
			* CFrame.Angles(0, 0, math.rad(90))
	end

	-- v.jalka = hantapotkuri: puomissa (2.1 takana), pyorii Y-akselin
	-- ympari pystytasossa
	J.hipL.C0 = CFrame.new(-0.5, -0.5, -2.15)
		* CFrame.Angles(state.tailAngle, math.rad(-90), 0)

	if isR15 then
		-- ketjun loppuosat suoriksi (identity jo resetoitu)
	end
end

local function poseBunny(t)
	local lift = state.liftPos
	local sq = state.squash
	local earBack = 0.22 + state.earAngle
	local twitch = math.rad(3) * math.sin(t * 1.7) + math.rad(1.5) * math.sin(t * 5.3)

	if state.special then
		sq = sq + 0.15 * math.abs(math.sin(state.specialT * 14))
	end

	-- root: pystyssa, pieni kyykky squashilla
	J.root.C0 = CFrame.new(0, -sq * 0.6, 0)

	-- paa: hieman ylos nostettuna, nykaisee
	J.neck.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(-8), twitch, 0)

	-- kadet = korvat: olkapaista suoraan ylos, earBack-kulma taakse
	-- identity = kasi alas; 180 Z = kasi ylos. earBack taivuttaa X:lla.
	J.shoulderR.C0 = CFrame.new(0.35, 0.55, 0)
		* CFrame.Angles(-earBack * 0.6, 0, math.rad(172))
	J.shoulderL.C0 = CFrame.new(-0.35, 0.55, 0)
		* CFrame.Angles(-earBack * 0.6, 0, math.rad(-172))

	-- jalat: kyykky -> ojennus liftin mukaan
	-- identity = jalka alas; kyykky = taakse-ylos-taivutus (X)
	local fold = math.rad(120 - 90 * lift) -- 120 kyykky -> 30 ojennus
	J.hipR.C0 = CFrame.new(0.25, -0.9, 0) * CFrame.Angles(fold, 0, 0)
	J.hipL.C0 = CFrame.new(-0.25, -0.9, 0) * CFrame.Angles(fold, 0, 0)

	if isR15 then
		-- polvet: kyykkyssa taivutettuna, ilmassa suorina
		local knee = math.rad(70 - 60 * lift)
		J.kneeR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(knee, 0, 0)
		J.kneeL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(knee, 0, 0)
	end
end

local function poseDog(t)
	local g = state.gaitPhase * math.pi * 2
	local swing = math.sin(g) * 0.55
	local pant = math.rad(5) * math.sin(t * 6)
	local bow = state.special

	-- root: neljajalkainen = runko vaakatasoon, mutta pystympi kuin heli
	local pitch = math.rad(-72)
	if state.downHeld then pitch = math.rad(-40) end -- istuminen
	if bow then pitch = math.rad(-88) end -- kumarrus
	J.root.C0 = CFrame.new(0, -0.15, 0) * CFrame.Angles(pitch, 0, 0)

	-- paa: ylos ja eteen, lorskahdus
	J.neck.C0 = CFrame.new(0, 0, 0)
		* CFrame.Angles(math.rad(55) + pant, math.rad(4) * math.sin(t * 2.2), 0)

	-- etujalat (kadet): alas, vinottainen rava
	local fR, fL = swing, -swing
	-- takajalat: vastakkaisessa vaiheessa
	local bR, bL = -swing, swing
	if bow then
		fR, fL = 1.1, 1.1
		bR = 0.25 * math.sin(t * 14)
		bL = 0.25 * math.sin(t * 14 + 1)
	end

	-- kadet: olkapaista alas (identity-suunta), keinu X:lla
	J.shoulderR.C0 = CFrame.new(0.4, 0.5, 0) * CFrame.Angles(fR, 0, math.rad(90))
	J.shoulderL.C0 = CFrame.new(-0.4, 0.5, 0) * CFrame.Angles(fL, 0, math.rad(-90))
	-- jalat: lantioista alas, keinu
	J.hipR.C0 = CFrame.new(0.25, -0.9, 0) * CFrame.Angles(bR, 0, 0)
	J.hipL.C0 = CFrame.new(-0.25, -0.9, 0) * CFrame.Angles(bL, 0, 0)

	if isR15 then
		-- kyynarpaat ja polvet hieman taipuneina (elainmaista)
		J.elbowR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(14), 0, 0)
		J.elbowL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(14), 0, 0)
		J.kneeR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(20), 0, 0)
		J.kneeL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(20), 0, 0)
	end
end

local function poseMonster(t)
	local g = state.gaitPhase * math.pi * 2
	local sway = math.rad(4) * math.sin(t * 1.4)
	local armSwing = math.sin(g) * 0.22
	local legSwing = math.sin(g) * 0.18
	local roar = state.special

	-- root: pysty, kumartunut eteenpain, keinuu
	J.root.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(-18), 0, sway)

	-- paa: alhaalla ja eteen tyontyneena
	if roar then
		J.neck.C0 = CFrame.new(0, 0, 0)
			* CFrame.Angles(math.rad(-38) + math.rad(5) * math.sin(t * 20), 0, 0)
		J.neck.C0 = addWobble(J.neck.C0, 0.03, 0.04)
	else
		J.neck.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(28), sway, 0)
	end

	if roar then
		-- kadet ylos ja levallaan
		J.shoulderR.C0 = CFrame.new(0.45, 0.5, 0)
			* CFrame.Angles(0, 0, math.rad(150 + 8 * math.sin(t * 18)))
		J.shoulderL.C0 = CFrame.new(-0.45, 0.5, 0)
			* CFrame.Angles(0, 0, math.rad(-150 - 8 * math.sin(t * 18)))
	else
		-- kadet pitkina roikkumaan eteen-alas
		J.shoulderR.C0 = CFrame.new(0.45, 0.5, 0)
			* CFrame.Angles(math.rad(-50) - armSwing * 40, 0, math.rad(12))
		J.shoulderL.C0 = CFrame.new(-0.45, 0.5, 0)
			* CFrame.Angles(math.rad(-50) + armSwing * 40, 0, math.rad(-12))
	end

	-- jalat: raskas keinu
	J.hipR.C0 = CFrame.new(0.25, -0.9, 0) * CFrame.Angles(-legSwing, 0, 0)
	J.hipL.C0 = CFrame.new(-0.25, -0.9, 0) * CFrame.Angles(legSwing, 0, 0)

	if isR15 then
		J.elbowR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(24), 0, 0)
		J.elbowL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(24), 0, 0)
	end
end

--============================================================--
--              RENDER-LUUPPI (posen paivitys)
--============================================================--
-- RenderStepped: asetetaan VAIN liitosten C0-arvoja. Fysiikan
-- solveri sijoittaa osat itse -> ei koskaan flingia.
RunService.RenderStepped:Connect(function(dt)
	if not state.enabled then return end
	if not hrp or hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end

	state.elapsed = state.elapsed + dt
	local t = state.elapsed

	stopAnimations()

	if state.mode == "HELI" then
		poseHeli(t)
	elseif state.mode == "BUNNY" then
		poseBunny(t)
	elseif state.mode == "DOG" then
		poseDog(t)
	else
		poseMonster(t)
	end
end)

--============================================================--
--            HEARTBEAT-LUUPPI (liike ja potkurit)
--============================================================--
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.Heartbeat:Connect(function(dt)
	if not state.enabled then return end
	if not hrp or hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end
	if not bodyVelocity or bodyVelocity.Parent == nil then return end

	local t = state.elapsed

	-- input
	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	local upInput = state.upHeld or humanoid.Jump
		or UserInputService:IsKeyDown(Enum.KeyCode.Space)
	local downInput = state.downHeld
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)

	-- lattia-raycast: laskeutuminen pysahtyy maahan
	rayParams.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -60, 0), rayParams)
	local floorY = hit and hit.Position.Y or nil
	local clearance = CFG.GroundClear[state.mode] or 2.2

	local desired

	if state.mode == "HELI" then
		local spd = CFG.ForwardSpeed
		if flat.Magnitude > 1e-3 then
			local cam = workspace.CurrentCamera
			local camLook = cam and cam.CFrame.LookVector or hrp.CFrame.LookVector
			local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
			if flatLook.Magnitude > 1e-3
				and flat.Unit:Dot(flatLook.Unit) < -0.3 then
				spd = CFG.BackwardSpeed
			end
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

		-- potkurit
		local cam = workspace.CurrentCamera
		local camLook = cam and cam.CFrame.LookVector or hrp.CFrame.LookVector
		local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
		if flatLook.Magnitude < 1e-3 then flatLook = Vector3.new(0, 0, -1) end
		flatLook = flatLook.Unit
		local fSpeed = state.velocity:Dot(flatLook)

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

	elseif state.mode == "DOG" then
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

	else -- MONSTER
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
	end

	-- lattiaklampi
	if floorY then
		local heightAbove = hrp.Position.Y - floorY
		if heightAbove < clearance + 0.2 and desired.Y < 0 then
			desired = Vector3.new(desired.X, 0, desired.Z)
		end
	end

	-- pehmennys ja rajoitus
	state.velocity = dampV3(state.velocity, desired, CFG.Acceleration, dt)
	if state.velocity.Magnitude > CFG.MaxSpeed then
		state.velocity = state.velocity.Unit * CFG.MaxSpeed
	end
	bodyVelocity.Velocity = state.velocity

	-- gyro: VAIN yaw kameran suuntaan (kuten referenssi-drone).
	-- Rungon kallistus tehdaan root-jointin kautta, ei taalla.
	local cam = workspace.CurrentCamera
	if cam then
		local lk = cam.CFrame.LookVector
		local pos = hrp.Position
		local target = CFrame.new(pos, pos + Vector3.new(lk.X, 0, lk.Z))
		if target.Position.X == target.Position.X then -- NaN-suoja
			bodyGyro.CFrame = target
		end
	end

	-- special-ajastin
	if state.special then
		state.specialT = state.specialT + dt
		if state.specialT >= (CFG.SpecialDuration[state.mode] or 2) then
			state.special = false
		end
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
		resetAllC0()
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

closeBtn.MouseButton1Click:Connect(function()
	gui.Enabled = false
end)

makeDraggable(main, titleBar)

-- ASCEND ja DESCEND hypynapin viereen
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
