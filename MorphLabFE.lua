--============================================================--
--  MORPH LAB FE (v7) - muuttaa hahmosi ajoneuvoiksi / elaimiksi
--
--  100% FE - ja nyt TODELLAKIN kaikille nakyva:
--    HELI ja MONSTER kayttavat julkaistuja emote-animaatioita.
--    Humanoidin Animatoriin ladatut animaatiot REPLIKOITUVAT
--    kaikille pelaajille automaattisesti (Robloxin sisainen
--    animaatioreplikointi) - tata ei voi tehda C0/CFrame-asetuksilla,
--    koska ne eivat koskaan replikoidu (vahvistettu DevForum).
--
--  ANIMAATIOT (koko ajan loopissa kun moodi paalla):
--    HELI    = "Helicopter" emote (110553756436163)
--    MONSTER = "Pain of Pains" emote (132985306809464)
--    BUNNY/DOG = ei julkaistua assetia -> lokaali joint-pose
--                (nakyvat omalla ruudulla, liike kaikille)
--
--  MUOKKAUS: animspeed skaalautuu liikenopeuteen (AdjustSpeed),
--    potkuri-/korva-/askelparametrit CFG:ssa.
--
--  LENTO: todistettu FE-drone-kaava - BodyVelocity +
--    yaw-only BodyGyro (P=9000). Ei flingia koska emme siirra
--    raajoja kauas jointeista emmeka kaanna gyron pitchia.
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
	-- animaatio-ID:t (emote -> sisainen Animation)
	AnimIds = {
		HELI    = "110553756436163",
		MONSTER = "132985306809464",
	},
	-- animspeed-rajat (muokkaus: nopeus skaalautuu liikkeeseen)
	AnimSpeedBase = 1.0,
	AnimSpeedGain = 0.6,   -- kuinka paljon liikenopeus kiihdyttaa animia
	AnimSpeedMax  = 2.2,
	-- heli
	ForwardSpeed   = 30,
	BackwardSpeed  = 14,
	ClimbSpeed     = 18,
	DescendSpeed   = 16,
	Acceleration   = 4,
	HoverBob       = 0.6,
	-- pupu
	BunnySpeed     = 24,
	BunnyHop       = 12,
	BunnyFall      = -6,
	BunnyBigJump   = 15,
	EarStiffness   = 110,
	EarDamping     = 9,
	EarAccelGain   = 0.0016,
	-- koira
	DogSpeed       = 34,
	DogLeap        = 13,
	-- monsteri
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

local J = {}      -- liitokset (vain BUNNY/DOG lokaaliposeihin)
local orig = {}
local animTracks = {}  -- [modeId] = AnimationTrack (ladatut)
local activeTrack = nil -- tama saa jaada soimaan stopAnimationsissa

--====================== APURIT ==============================--
local function damp(a, b, k, dt)
	return a + (b - a) * (1 - math.exp(-k * dt))
end

local function dampV3(a, b, k, dt)
	return a:Lerp(b, 1 - math.exp(-k * dt))
end

local function wobble(cf, posMag, rotMag)
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

-- pysayta kaikki PAITSIN oma aktivinen morffi-animmme
local function stopAnimations()
	if not animator then return end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track ~= activeTrack then
			track:Stop(0)
		end
	end
end

--============================================================--
--              ANIMAATIOIDEN LATAUS (FE-replikoituva)
--============================================================--
-- Katalogi-emote: sisainen Animation etsitaan kuten toimivassa
-- FE-drone-referenssissa; fallback = suora rbxassetid.
local function resolveAnimation(assetId)
	local targetId = "rbxassetid://" .. assetId

	-- 1) GetObjects (exekuuttori-tuki, kuten referenssissa)
	local ok, objects = pcall(function()
		return game:GetObjects(targetId)
	end)
	if ok and objects then
		for _, obj in ipairs(objects) do
			if obj:IsA("Animation") then
				return obj.AnimationId
			end
			for _, desc in ipairs(obj:GetDescendants()) do
				if desc:IsA("Animation") then
					return desc.AnimationId
				end
			end
		end
	end

	-- 2) suora ID (emoteilla katalogi-ID toimii animaationa)
	return targetId
end

local function getAnimTrack(modeId)
	if animTracks[modeId] then
		return animTracks[modeId]
	end
	local assetId = CFG.AnimIds[modeId]
	if not assetId or not animator then return nil end

	local ok, track = pcall(function()
		local anim = Instance.new("Animation")
		anim.AnimationId = resolveAnimation(assetId)
		local t = animator:LoadAnimation(anim)
		t.Looped = true
		t.Priority = Enum.AnimationPriority.Action4 -- voittaa oletusanimit
		return t
	end)
	if ok and track then
		animTracks[modeId] = track
		return track
	end
	return nil
end

--====================== RIGIN SITOMINEN =====================--
local function bindCharacter(c)
	char = c
	humanoid = c:WaitForChild("Humanoid")
	hrp = c:WaitForChild("HumanoidRootPart")
	isR15 = humanoid.RigType == Enum.HumanoidRigType.R15

	J = {}
	orig = {}
	animTracks = {}
	activeTrack = nil

	local function grab(motor, key)
		orig[motor] = { c0 = motor.C0, c1 = motor.C1 }
		J[key] = motor
	end

	if isR15 then
		local lower = c:WaitForChild("LowerTorso")
		local upper = c:WaitForChild("UpperTorso")
		grab(hrp:WaitForChild("RootJoint"), "root")
		grab(upper:WaitForChild("Neck"), "neck")
		grab(upper:WaitForChild("RightShoulder"), "shoulderR")
		grab(upper:WaitForChild("LeftShoulder"), "shoulderL")
		grab(lower:WaitForChild("RightHip"), "hipR")
		grab(lower:WaitForChild("LeftHip"), "hipL")
		grab(c:WaitForChild("RightUpperArm"):WaitForChild("RightElbow"), "elbowR")
		grab(c:WaitForChild("LeftUpperArm"):WaitForChild("LeftElbow"), "elbowL")
		grab(c:WaitForChild("RightUpperLeg"):WaitForChild("RightKnee"), "kneeR")
		grab(c:WaitForChild("LeftUpperLeg"):WaitForChild("LeftKnee"), "kneeL")
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

--====================== ANIMAATIO-OHJ AUS ===================--
local function playModeAnim(modeId)
	-- pysayta vanha
	if activeTrack then
		pcall(function() activeTrack:Stop(0.1) end)
		activeTrack = nil
	end
	-- jos moodilla on julkaistu animaatio, kayta sita (replikoituu!)
	local track = getAnimTrack(modeId)
	if track then
		activeTrack = track
		pcall(function()
			track:Play(0.1)
			track:AdjustSpeed(CFG.AnimSpeedBase)
		end)
	end
end

local function stopModeAnim()
	if activeTrack then
		pcall(function() activeTrack:Stop(0.1) end)
		activeTrack = nil
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
	state.earAngle, state.earVel = 0, 0
	state.hopPhase, state.gaitPhase = 0, 0
	state.thumpPulse = 0

	if animateScript then animateScript.Disabled = true end
	stopAnimations()

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
	local lk = hrp.CFrame.LookVector
	bodyGyro.CFrame = CFrame.new(hrp.Position,
		hrp.Position + Vector3.new(lk.X, 0, lk.Z))
	bodyGyro.Parent = hrp

	-- kaynnista moodin animaatio (FE-replikoituva jos julkaistu)
	playModeAnim(state.mode)

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

	stopModeAnim()
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
--        LOKAALIT POSET vain BUNNY/DOG (ei julkaistua animia)
--============================================================--
local function poseBunny(t)
	local lift = state.liftPos
	local sq = state.squash
	local earBack = 0.22 + state.earAngle
	local twitch = math.rad(3) * math.sin(t * 1.7) + math.rad(1.5) * math.sin(t * 5.3)

	if state.special then
		sq = sq + 0.15 * math.abs(math.sin(state.specialT * 14))
	end

	J.root.C0 = CFrame.new(0, -sq * 0.6, 0)
	J.neck.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(-8), twitch, 0)

	J.shoulderR.C0 = CFrame.new(0.35, 0.55, 0)
		* CFrame.Angles(-earBack * 0.6, 0, math.rad(172))
	J.shoulderL.C0 = CFrame.new(-0.35, 0.55, 0)
		* CFrame.Angles(-earBack * 0.6, 0, math.rad(-172))

	local fold = math.rad(120 - 90 * lift)
	J.hipR.C0 = CFrame.new(0.25, -0.9, 0) * CFrame.Angles(fold, 0, 0)
	J.hipL.C0 = CFrame.new(-0.25, -0.9, 0) * CFrame.Angles(fold, 0, 0)

	if isR15 then
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

	local pitch = math.rad(-72)
	if state.downHeld then pitch = math.rad(-40) end
	if bow then pitch = math.rad(-88) end
	J.root.C0 = CFrame.new(0, -0.15, 0) * CFrame.Angles(pitch, 0, 0)

	J.neck.C0 = CFrame.new(0, 0, 0)
		* CFrame.Angles(math.rad(55) + pant, math.rad(4) * math.sin(t * 2.2), 0)

	local fR, fL = swing, -swing
	local bR, bL = -swing, swing
	if bow then
		fR, fL = 1.1, 1.1
		bR = 0.25 * math.sin(t * 14)
		bL = 0.25 * math.sin(t * 14 + 1)
	end

	J.shoulderR.C0 = CFrame.new(0.4, 0.5, 0) * CFrame.Angles(fR, 0, math.rad(90))
	J.shoulderL.C0 = CFrame.new(-0.4, 0.5, 0) * CFrame.Angles(fL, 0, math.rad(-90))
	J.hipR.C0 = CFrame.new(0.25, -0.9, 0) * CFrame.Angles(bR, 0, 0)
	J.hipL.C0 = CFrame.new(-0.25, -0.9, 0) * CFrame.Angles(bL, 0, 0)

	if isR15 then
		J.elbowR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(14), 0, 0)
		J.elbowL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(14), 0, 0)
		J.kneeR.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(20), 0, 0)
		J.kneeL.C0 = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(20), 0, 0)
	end
end

--============================================================--
--            HEARTBEAT-LUUPPI (liike + anim-nopeus)
--============================================================--
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.Heartbeat:Connect(function(dt)
	if not state.enabled then return end
	if not hrp or hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end
	if not bodyVelocity or bodyVelocity.Parent == nil then return end

	state.elapsed = state.elapsed + dt
	local t = state.elapsed

	stopAnimations()
	if humanoid.Sit then humanoid.Sit = false end
	if humanoid.SeatPart then humanoid.Sit = false end

	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	local upInput = state.upHeld or humanoid.Jump
		or UserInputService:IsKeyDown(Enum.KeyCode.Space)
	local downInput = state.downHeld
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)

	-- lattia-raycast
	rayParams.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -60, 0), rayParams)
	local floorY = hit and hit.Position.Y or nil
	local clearance = CFG.GroundClear[state.mode] or 2.2

	local cam = workspace.CurrentCamera
	local camLook = cam and cam.CFrame.LookVector or hrp.CFrame.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 1e-3 then flatLook = Vector3.new(0, 0, -1) end
	flatLook = flatLook.Unit

	local desired

	if state.mode == "HELI" then
		local spd = CFG.ForwardSpeed
		if flat.Magnitude > 1e-3 and flat.Unit:Dot(flatLook) < -0.3 then
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

	state.velocity = dampV3(state.velocity, desired, CFG.Acceleration, dt)
	if state.velocity.Magnitude > CFG.MaxSpeed then
		state.velocity = state.velocity.Unit * CFG.MaxSpeed
	end
	bodyVelocity.Velocity = state.velocity

	-- gyro: VAIN yaw (drone-kaava)
	if cam then
		local pos = hrp.Position
		local target = CFrame.new(pos, pos + Vector3.new(flatLook.X, 0, flatLook.Z))
		if target.Position.X == target.Position.X then
			bodyGyro.CFrame = target
		end
	end

	-- MUOKKAUS: anim-nopeus skaalautuu liikenopeuteen
	if activeTrack then
		local mag = state.velocity.Magnitude
		local speed = math.clamp(
			CFG.AnimSpeedBase + (mag / math.max(CFG.ForwardSpeed, 1)) * CFG.AnimSpeedGain,
			0, CFG.AnimSpeedMax)
		pcall(function() activeTrack:AdjustSpeed(speed) end)
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
		local src = CFG.AnimIds[state.mode] and "ANIM" or "LOCAL"
		statusLabel.Text = string.format(
			"%s [%s]  |  %d studs/s",
			modeInfo().name, src,
			math.floor(state.velocity.Magnitude + 0.5)
		)
	end
end)

--============================================================--
--        RENDER-LUUPPI (vain BUNNY/DOG lokaalipose)
--============================================================--
RunService.RenderStepped:Connect(function()
	if not state.enabled then return end
	if not hrp or hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end

	-- HELI/MONSTER: julkaistu animaatio hoitaa posen (replikoituu).
	-- BUNNY/DOG: ei assetia -> lokaali joint-pose.
	local t = state.elapsed
	if state.mode == "BUNNY" then
		poseBunny(t)
	elseif state.mode == "DOG" then
		poseDog(t)
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
		-- vaihda animaatio moodin mukaan
		if state.enabled then
			playModeAnim(state.mode)
		end
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
