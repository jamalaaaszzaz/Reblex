--============================================================--
--  HELIKOPTERI FE (R6) - muuttaa hahmosi helikopteriksi
--
--  100% FE: ei luoda yhtaan uutta partia, kaikki tehaan oman
--  hahmon raajoille jokaisessa Stepped-framessa -> kaikki
--  pelaajat nakevat muodonmuutoksen.
--
--  Rakenne:
--    Vartalo      = runko (makaa vaakatasossa)
--    Paa          = ohjaamo (pysyy pystyssa, edessa)
--    Oikea kasi   = masto (pistaa selasta ylos)
--    Oikea jalka  = paapotkuri (pyorii maston paassa)
--    Vasen kasi   = hantapuomi
--    Vasen jalka  = hantapotkuri (pyorii puomissa)
--
--  Ohjaus:
--    WASD            = liiku (eteenpain = nopein)
--    HYPPY (space)   = nousu, paapotkuri kihahtaa
--    LASKU-nappi     = laskeutuminen, potkurit hiljenevat
--                      (nappi ilmestyy hypyn viereen, PC:lla myos CTRL)
--    CRASHOUT        = kaatumisanimaatio (paa taakse, kadet
--                      peraan, tarkinaa, potkurit sahaavat)
--    RightShift      = piilota / nayta GUI
--============================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

--====================== ASETUKSET ===========================--
local CFG = {
	ForwardSpeed   = 30,    -- studs/s eteenpain
	BackwardSpeed  = 14,    -- studs/s taaksepain
	ClimbSpeed     = 20,    -- nousunopeus
	DescendSpeed   = 18,    -- laskunopeus
	Acceleration   = 4,     -- liikkeen pehmennys (vakio)
	ForwardTilt    = 22,    -- kuinka paljon nokka kallistuu kiihdytettaessa
	BankTilt       = 14,    -- sivuttaisliikkeen kallistus
	HoverBob       = 0.8,   -- leijunnan pieni heilahtelu
	MainRotorIdle  = 8,     -- paapotkurin rad/s leijunnassa
	MainRotorMax   = 30,    -- paapotkurin rad/s nousussa
	MainRotorMin   = 5,     -- paapotkurin rad/s laskussa
	TailRotorIdle  = 7,     -- hantapotkurin rad/s
	TailRotorMax   = 30,
	TailRotorGain  = 0.9,   -- kuinka paljon eteenpain vauhti kiihdyttaa hantaa
	RotorResponse  = 2.6,   -- potkurin kiihdytystahti (spool up/down)
	CrashoutDuration = 2.4, -- sekuntia
}

--======================== TILA ==============================--
local state = {
	enabled     = false,
	crashing    = false,
	crashT      = 0,
	elapsed     = 0,
	rotorAngle  = 0,
	tailAngle   = 0,
	mainSpeed   = CFG.MainRotorIdle,
	tailSpeed   = CFG.TailRotorIdle,
	velocity    = Vector3.zero,
	look        = Vector3.new(0, 0, -1),
	descendHeld = false,
}

local char, humanoid, hrp, torso, head, armR, armL, legR, legL, animator, animateScript
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

local function bindCharacter(c)
	char = c
	humanoid = c:WaitForChild("Humanoid")
	hrp = c:WaitForChild("HumanoidRootPart")
	torso = c:WaitForChild("Torso")
	head = c:WaitForChild("Head")
	armR = c:WaitForChild("Right Arm")
	armL = c:WaitForChild("Left Arm")
	legR = c:WaitForChild("Right Leg")
	legL = c:WaitForChild("Left Leg")
	animator = humanoid:WaitForChild("Animator")
	animateScript = c:FindFirstChild("Animate")
end

local function stopAnimations()
	if not animator then return end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
	end
end

local function setBodyCollisions(value)
	for _, p in ipairs({head, torso, armR, armL, legR, legL}) do
		if p then p.CanCollide = value end
	end
end

--====================== PAALLA / POIS =======================--
local updateToggleButton -- maaritellaan GUI-osassa
local descendBtn         -- maaritellaan GUI-osassa
local statusLabel

local function enable()
	if state.enabled then return end
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R6 then
		if statusLabel then statusLabel.Text = "TARVITSET R6-AVATARIN" end
		return
	end

	state.enabled = true
	state.crashing = false
	state.crashT = 0
	state.elapsed = 0
	state.velocity = Vector3.zero
	state.mainSpeed = CFG.MainRotorIdle
	state.tailSpeed = CFG.TailRotorIdle

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

	-- pieni ponnaus ilmaan ettei runko jaa maahan kiinni
	hrp.CFrame = hrp.CFrame + Vector3.new(0, 2.5, 0)

	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	bodyVelocity.Velocity = Vector3.zero
	bodyVelocity.Parent = hrp

	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	bodyGyro.D = 800
	bodyGyro.P = 1e5
	bodyGyro.CFrame = hrp.CFrame
	bodyGyro.Parent = hrp

	if descendBtn then descendBtn.Visible = true end
	updateToggleButton()
end

local function disable()
	if not state.enabled then return end
	state.enabled = false
	state.crashing = false
	state.descendHeld = false

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

local function crashout()
	if not state.enabled or state.crashing then return end
	state.crashing = true
	state.crashT = 0
end

--====================== PAALUUPPI ===========================--
RunService.Stepped:Connect(function(_, dt)
	if not state.enabled then return end
	if not hrp or hrp.Parent == nil or not humanoid or humanoid.Parent == nil then return end

	state.elapsed = state.elapsed + dt
	local t = state.elapsed

	-- pakota kaikki pelin animaatiot pois (myos emotet)
	stopAnimations()
	if humanoid.Sit then humanoid.Sit = false end

	-- suunta kamerasta (tasannea XZ-tasoon)
	local cam = workspace.CurrentCamera
	local camLook = cam and cam.CFrame.LookVector or hrp.CFrame.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 1e-3 then
		flatLook = state.look
	else
		flatLook = flatLook.Unit
	end
	state.look = dampV3(state.look, flatLook, 6, dt)
	local look = state.look.Unit
	local right = look:Cross(Vector3.yAxis)

	-- input -> haluttu nopeus
	local md = humanoid.MoveDirection
	local flat = Vector3.new(md.X, 0, md.Z)
	local spd = CFG.ForwardSpeed
	if flat.Magnitude > 1e-3 and flat.Unit:Dot(look) < -0.3 then
		spd = CFG.BackwardSpeed
	end
	local horizDesired = flat * spd

	local upInput = humanoid.Jump
	local downInput = state.descendHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
	local vertical = 0
	if upInput and not downInput then
		vertical = CFG.ClimbSpeed
	elseif downInput and not upInput then
		vertical = -CFG.DescendSpeed
	else
		vertical = math.sin(t * 2.1) * CFG.HoverBob
	end
	if state.crashing then
		vertical = vertical + (rng:NextNumber() - 0.5) * 10
	end

	local desired = horizDesired + Vector3.new(0, vertical, 0)
	state.velocity = dampV3(state.velocity, desired, CFG.Acceleration, dt)
	bodyVelocity.Velocity = state.velocity

	-- kallistukset: nokka alas kiihdyttaessa, sivuttaisliike kallistaa
	local fSpeed = state.velocity:Dot(look)
	local sSpeed = state.velocity:Dot(right)
	local pitchExtra = -math.rad(CFG.ForwardTilt) * math.clamp(fSpeed / CFG.ForwardSpeed, -1, 1)
	local roll = -math.rad(CFG.BankTilt) * math.clamp(sSpeed / CFG.ForwardSpeed, -1, 1)

	local jx, jy, jz = 0, 0, 0
	if state.crashing then
		jx = (rng:NextNumber() - 0.5) * math.rad(10)
		jy = (rng:NextNumber() - 0.5) * math.rad(10)
		jz = (rng:NextNumber() - 0.5) * math.rad(10)
	end

	local pos = hrp.Position
	bodyGyro.CFrame = CFrame.lookAt(pos, pos + look)
		* CFrame.Angles(math.rad(-90) + pitchExtra + jx, 0, 0)
		* CFrame.Angles(0, roll + jy, 0)
		* CFrame.Angles(0, 0, jz)

	-- potkurinopeudet
	local mainTarget = CFG.MainRotorIdle
	if upInput then
		mainTarget = CFG.MainRotorMax
	elseif downInput then
		mainTarget = CFG.MainRotorMin
	end
	if state.crashing then
		mainTarget = 4 + 9 * math.abs(math.sin(t * 6.5))
	end
	local tailTarget = math.clamp(
		CFG.TailRotorIdle + CFG.TailRotorGain * math.max(0, fSpeed),
		0, CFG.TailRotorMax
	)
	if state.crashing then
		tailTarget = tailTarget * (0.4 + 0.6 * math.abs(math.sin(t * 9)))
	end
	state.mainSpeed = damp(state.mainSpeed, mainTarget, CFG.RotorResponse, dt)
	state.tailSpeed = damp(state.tailSpeed, tailTarget, CFG.RotorResponse, dt)
	state.rotorAngle = (state.rotorAngle + state.mainSpeed * dt) % (math.pi * 2)
	state.tailAngle = (state.tailAngle + state.tailSpeed * dt) % (math.pi * 2)

	if state.crashing then
		state.crashT = state.crashT + dt
		if state.crashT >= CFG.CrashoutDuration then
			state.crashing = false
		end
	end

	--===================== POSEN MUOTOILU ====================--
	local base = hrp.CFrame
	local crash = state.crashing

	-- vartalo = runko
	local torsoCF = base
	if crash then
		torsoCF = torsoCF * shakeCF(0.1, 0.09)
	end
	torso.CFrame = torsoCF

	-- paa = ohjaamo (pysyy pystyssa ja edessa; crashissa taakse ja ylos)
	if crash then
		head.CFrame = base
			* CFrame.new(0, 1.30, 0.55)
			* CFrame.Angles(math.rad(125) + math.rad(6) * math.sin(t * 16), 0, 0)
			* shakeCF(0.07, 0.1)
	else
		head.CFrame = base
			* CFrame.new(0, 1.55, 0.28)
			* CFrame.Angles(math.rad(90), 0, 0)
	end

	-- oikea kasi = masto selasta ylos
	local mastPos = base * CFrame.new(0, -0.45, 1.05)
	if crash then
		armR.CFrame = mastPos
			* CFrame.Angles(math.rad(155), 0, 0)
			* CFrame.new(0, 1, 0)
	else
		armR.CFrame = mastPos
			* CFrame.Angles(math.rad(90) + math.rad(2.5) * math.sin(t * 2.3), 0, 0)
			* CFrame.new(0, 1, 0)
	end

	-- oikea jalka = paapotkuri maston paassa
	local bladeBase = mastPos
		* CFrame.new(0, 0, 2.05)
		* CFrame.Angles(0, 0, state.rotorAngle)
	legR.CFrame = bladeBase * CFrame.Angles(0, 0, math.rad(-90))

	-- vasen kasi = hantapuomi
	local tailRoot = base * CFrame.new(0, -1.05, 0.3)
	if crash then
		armL.CFrame = tailRoot
			* CFrame.Angles(math.rad(220), 0, 0)
			* CFrame.new(0, 1, 0)
	else
		armL.CFrame = tailRoot
			* CFrame.Angles(math.rad(180), 0, 0)
			* CFrame.new(0, 1, 0)
	end

	-- vasen jalka = hantapotkuri puomissa
	local tailSpin = tailRoot
		* CFrame.new(0, -2.15, 0.05)
		* CFrame.Angles(0, state.tailAngle, 0)
	legL.CFrame = tailSpin * CFrame.Angles(math.rad(90), 0, 0)

	-- tilanayton paivitys
	if statusLabel then
		statusLabel.Text = string.format(
			"ROTORI %d%%  -  HANTA %d%%  -  %d studs/s",
			math.floor(state.mainSpeed / CFG.MainRotorMax * 100 + 0.5),
			math.floor(state.tailSpeed / CFG.TailRotorMax * 100 + 0.5),
			math.floor(state.velocity.Magnitude + 0.5)
		)
	end
end)

--======================== GUI ===============================--
local gui = Instance.new("ScreenGui")
gui.Name = "HelikopteriGUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local COLORS = {
	bg        = Color3.fromRGB(16, 18, 27),
	panel     = Color3.fromRGB(34, 38, 54),
	accent    = Color3.fromRGB(0, 170, 255),
	green     = Color3.fromRGB(46, 204, 113),
	red       = Color3.fromRGB(231, 76, 60),
	orange    = Color3.fromRGB(230, 126, 34),
	text      = Color3.fromRGB(235, 240, 255),
	textDim   = Color3.fromRGB(150, 158, 180),
}

local function roundify(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = obj
end

local function strokeify(obj, transparency)
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(1, 1, 1)
	s.Transparency = transparency or 0.88
	s.Thickness = 1
	s.Parent = obj
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
main.Size = UDim2.new(0, 250, 0, 186)
main.Position = UDim2.new(0, 24, 0.5, -93)
main.BackgroundColor3 = COLORS.bg
main.BackgroundTransparency = 0.18
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui
roundify(main, 12)
strokeify(main)

-- otsikkorivi (taalta voi raahata)
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 27, 39)
titleBar.BackgroundTransparency = 0.1
titleBar.BorderSizePixel = 0
titleBar.Parent = main
roundify(titleBar, 12)

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
title.Text = "HELICOPTER  -  FE"
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
content.Size = UDim2.new(1, 0, 1, -36)
content.Position = UDim2.new(0, 0, 0, 36)
content.BackgroundTransparency = 1
content.Parent = main

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 20)
statusLabel.Position = UDim2.new(0, 12, 0, 8)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 11
statusLabel.TextColor3 = COLORS.accent
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = "VALMIS"
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
	return b
end

local toggleBtn = makeButton("KAYNNISTA", COLORS.green, 32, 38)
local crashBtn = makeButton("CRASHOUT", COLORS.orange, 76, 38)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -24, 0, 26)
hint.Position = UDim2.new(0, 12, 0, 120)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextColor3 = COLORS.textDim
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Text = "HYPPY = nousu   |   LASKU / CTRL = lasku\nRightShift = piilota tama valikko"
hint.Parent = content

-- toggle-napin varit tilan mukaan
updateToggleButton = function()
	if state.enabled then
		toggleBtn.Text = "PYSAYTA"
		toggleBtn.BackgroundColor3 = COLORS.red
	else
		toggleBtn.Text = "KAYNNISTA"
		toggleBtn.BackgroundColor3 = COLORS.green
		if statusLabel then statusLabel.Text = "VALMIS" end
	end
end

toggleBtn.MouseButton1Click:Connect(function()
	if state.enabled then
		disable()
	else
		enable()
	end
end)

crashBtn.MouseButton1Click:Connect(function()
	crashout()
end)

-- pienennys
local minimized = false
local fullSize = main.Size
local miniSize = UDim2.new(0, 250, 0, 36)
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
		{Size = target}
	)
	tween:Play()
	if not minimized then
		tween.Completed:Connect(function()
			content.Visible = true
		end)
	end
end)

makeDraggable(main, titleBar)

-- LASKU-nappi: hypynapin viereen (mobiilissa), PC:lla sama nappi nakyy
descendBtn = Instance.new("TextButton")
descendBtn.Name = "LaskeutumisNappi"
descendBtn.Size = UDim2.new(0, 74, 0, 74)
descendBtn.Position = UDim2.new(1, -184, 1, -164)
descendBtn.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
descendBtn.BackgroundTransparency = 0.35
descendBtn.Font = Enum.Font.GothamBold
descendBtn.TextSize = 15
descendBtn.TextColor3 = COLORS.accent
descendBtn.Text = "v\nLASKU"
descendBtn.BorderSizePixel = 0
descendBtn.Visible = false
descendBtn.Parent = gui
roundify(descendBtn, 16)
strokeify(descendBtn, 0.7)

descendBtn.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.descendHeld = true
	end
end)
descendBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		state.descendHeld = false
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
