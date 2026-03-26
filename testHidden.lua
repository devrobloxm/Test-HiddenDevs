-- ParkourSystem ModuleScript
-- All systems merged into one file: Movement, Jump, Dash, Slide, Vault, WallRun, Climb


local ParkourSystem = {}

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")
local resource   = game.ReplicatedStorage.Resource


-- State


local State = {
	speed         = 16,
	stamina       = 100,
	hasMomentum   = false,
	isRunning     = false,
	isDashing     = false,
	isWallRunning = false,
	isClimbing    = false,
	isVaulting    = false,
	isSliding     = false,
	isAirborne    = false,
	jumpCount     = 0,
}

local parkourState = "idle"
-- idle | climbing | wallrunning | dashing | sliding | vaulting

local function stateIs(s)    return parkourState == s end
local function stateSet(s)   parkourState = s end
local function stateReset()  parkourState = "idle" end
local function canClimb()    return parkourState == "idle" end
local function canWallRun()  return parkourState == "idle" end

local function inParkour()
	return State.isWallRunning or State.isClimbing
		or State.isVaulting    or State.isDashing
		or State.isSliding
end

local function breakMomentum()
	State.hasMomentum = false
	State.speed       = 16
end

-- called every RenderStepped frame
local STAMINA_MAX          = 100
local STAMINA_DRAIN_SLOW   = 2
local STAMINA_DRAIN_GROUND = 8
local STAMINA_DRAIN_PARKOUR = 15
local STAMINA_REGEN        = 4

local function updateStamina(dt)
	if State.isRunning or inParkour() then
		local drain
		if State.hasMomentum then
			drain = STAMINA_DRAIN_SLOW
		else
			drain = inParkour() and STAMINA_DRAIN_PARKOUR or STAMINA_DRAIN_GROUND
		end
		State.stamina = math.clamp(State.stamina - drain * dt, 0, STAMINA_MAX)
	else
		State.stamina = math.clamp(State.stamina + STAMINA_REGEN * dt, 0, STAMINA_MAX)
	end
	if State.stamina <= 0 then breakMomentum() end
end


-- AnimationController


local ANIM_PRIORITY = {
	Idle         = 0,
	Walk         = 1,
	AccelRun     = 2,
	Sprint       = 3,
	Slide1       = 4,
	Slide2       = 4,
	WallRunLeft  = 5,
	WallRunRight = 5,
	Climb        = 5,
	ClimbUp      = 6,
	ClimbJumpOff = 7,
	WallHopLeft  = 7,
	WallHopRight = 7,
	MonkeyVault  = 7,
	SideVault    = 7,
	ForwardRoll  = 8,
	BackRoll     = 8,
	LeftRoll     = 8,
	RightRoll    = 8,
	AirDash      = 8,
	DoubleJump   = 6,
	DoubleJump2  = 6,
	Fall         = 2,
	Landed       = 6,
	LightLanded  = 5,
}

-- these play and finish freely without affecting currentAnim
local TRANSIENT_ANIMS = {
	Landed       = true,
	LightLanded  = true,
	DoubleJump   = true,
	DoubleJump2  = true,
	ClimbJumpOff = true,
	WallHopLeft  = true,
	WallHopRight = true,
	MonkeyVault  = true,
	SideVault    = true,
	ForwardRoll  = true,
	BackRoll     = true,
	LeftRoll     = true,
	RightRoll    = true,
	AirDash      = true,
}

local animTracks    = {}
local currentAnim   = nil
local currentPrio   = -1
local lockedAnims   = {}

local Anim = {}

function Anim.register(name, track)
	animTracks[name] = track
end

function Anim.lockTo(names)
	lockedAnims = {}
	for _, n in ipairs(names) do lockedAnims[n] = true end
end

function Anim.unlock()
	lockedAnims = {}
end

function Anim.play(name, fadein)
	local track = animTracks[name]
	if not track then return end
	if next(lockedAnims) and not lockedAnims[name] then return end

	local prio = ANIM_PRIORITY[name] or 0

	if TRANSIENT_ANIMS[name] then
		if track.IsPlaying then track:Stop(0) end
		track:Play(fadein or 0.1)
		return
	end

	if prio < currentPrio then return end

	if currentAnim and currentAnim ~= name then
		local old = animTracks[currentAnim]
		if old and old.IsPlaying then old:Stop(fadein or 0.15) end
		currentAnim = nil
		currentPrio = -1
	end

	track:Stop(0)
	track:Play(fadein or 0.1)
	currentAnim = name
	currentPrio = prio
end

function Anim.stop(name, fadeout)
	local track = animTracks[name]
	if track and track.IsPlaying then
		track:Stop(fadeout or 0.15)
	end
	if currentAnim == name then
		currentAnim = nil
		currentPrio = -1
	end
end

function Anim.stopAll(fadeout)
	for _, t in pairs(animTracks) do
		if t.IsPlaying then t:Stop(fadeout or 0.15) end
	end
	currentAnim = nil
	currentPrio = -1
end

function Anim.isPlaying(name)
	local t = animTracks[name]
	return t ~= nil and t.IsPlaying
end


-- Init


local initialized = false

function ParkourSystem:init()
	if initialized then return end
	initialized = true

	local Player    = Players.LocalPlayer
	local Character = Player.Character or Player.CharacterAdded:Wait()
	local HRP       = Character:WaitForChild("HumanoidRootPart")
	local Humanoid  = Character:WaitForChild("Humanoid")
	local Animator  = Humanoid:WaitForChild("Animator")

	local animateScript = Character:FindFirstChild("Animate")
	if animateScript then animateScript.Enabled = false end
	for _, t in pairs(Animator:GetPlayingAnimationTracks()) do t:Stop(0) end

	local function reg(name)
		local track = Animator:LoadAnimation(resource.Animations[name])
		Anim.register(name, track)
		return track
	end

	-- register all animation tracks
	reg("Walk")
	reg("AccelRun")
	reg("Sprint")
	reg("DoubleJump")
	reg("DoubleJump2")
	reg("Fall")
	reg("Landed")
	reg("LightLanded")
	reg("ForwardRoll")
	reg("BackRoll")
	reg("LeftRoll")
	reg("RightRoll")
	reg("AirDash")
	reg("Slide1")
	reg("Slide2")
	reg("MonkeyVault")
	reg("SideVault")
	reg("WallRunLeft")
	reg("WallRunRight")
	animTracks.WallRunLeft.Looped  = true
	animTracks.WallRunRight.Looped = true

	local climbTrack    = reg("Climb")
	local climbUpTrack  = reg("ClimbUp")
	local jumpOffTrack  = reg("ClimbJumpOff")
	climbTrack.Looped   = true

	-- shared params used across all systems
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {Character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local function castDir(origin, dir, dist)
		dist = dist or 3.2
		local hit = workspace:Raycast(origin, dir * dist, rayParams)
		if hit and math.abs(hit.Normal.Y) < 0.85 then return hit end
		return nil
	end

	local function castFront(dist)
		return castDir(HRP.Position, HRP.CFrame.LookVector, dist)
	end

	local function isOnGround()
		return workspace:Raycast(HRP.Position, Vector3.new(0, -3.5, 0), rayParams) ~= nil
	end

	local function getTotalMass()
		local m = 0
		for _, p in ipairs(Character:GetDescendants()) do
			if p:IsA("BasePart") then m += p.AssemblyMass end
		end
		return m
	end

	
	-- Movement


	local WALK_SPEED       = 16
	local MAX_RUN_SPEED    = 80
	local SPRINT_THRESHOLD = 60
	local DECEL_RATE       = 40
	local SPEED_CURVE      = {5, 10, 15, 20, 30}

	local isWalking      = false
	local isDecelerating = false
	local isFullSprint   = false
	local curveIndex     = 1
	local accelTimer     = 0

	local function handleMovement(dt)
		local moveDir = Humanoid.MoveDirection.Magnitude
		updateStamina(dt)

		if inParkour() then
			isWalking = false; isFullSprint = false; isDecelerating = false
			return
		end

		if State.isRunning and State.stamina > 0 and moveDir > 0 then
			isWalking = false; isDecelerating = false
			accelTimer += dt
			if accelTimer >= 0.15 and curveIndex <= #SPEED_CURVE then
				State.speed = math.min(State.speed + SPEED_CURVE[curveIndex], MAX_RUN_SPEED)
				curveIndex += 1; accelTimer = 0
				if State.speed >= MAX_RUN_SPEED then State.hasMomentum = true end
			end
			Humanoid.WalkSpeed = State.speed
			if State.speed >= SPRINT_THRESHOLD then
				if not isFullSprint then
					isFullSprint = true
					Anim.stop("AccelRun"); Anim.play("Sprint")
				end
			else
				if isFullSprint then
					isFullSprint = false
					Anim.stop("Sprint"); Anim.play("AccelRun")
				elseif not Anim.isPlaying("AccelRun") then
					Anim.play("AccelRun")
				end
			end

		elseif State.speed > WALK_SPEED then
			isDecelerating = true; isWalking = false
			curveIndex = 1; accelTimer = 0
			State.speed = math.max(State.speed - DECEL_RATE * dt, WALK_SPEED)
			Humanoid.WalkSpeed = State.speed
			if State.speed >= SPRINT_THRESHOLD then
				if not Anim.isPlaying("Sprint") then Anim.stop("AccelRun"); Anim.play("Sprint") end
			elseif State.speed > WALK_SPEED + 2 then
				if not Anim.isPlaying("AccelRun") then Anim.stop("Sprint"); Anim.play("AccelRun") end
			else
				isFullSprint = false; isDecelerating = false
				Anim.stop("Sprint", 0.2); Anim.stop("AccelRun", 0.2)
			end

		else
			curveIndex = 1; accelTimer = 0
			isFullSprint = false; isDecelerating = false; isWalking = false
			Humanoid.WalkSpeed = WALK_SPEED; State.speed = WALK_SPEED
			Anim.stop("AccelRun", 0.15); Anim.stop("Sprint", 0.15)
			if moveDir > 0 then
				isWalking = true
				if not Anim.isPlaying("Walk") then Anim.play("Walk") end
			else
				Anim.stop("Walk", 0.15)
			end
		end
	end


	-- Jump / DoubleJump
	

	local MAX_JUMPS = 8

	Humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Landed then
			State.jumpCount = 0; State.isAirborne = false
			Anim.stop("Fall", 0.1)
			Anim.stop("DoubleJump", 0.1)
			Anim.stop("DoubleJump2", 0.1)
			if State.speed >= 60 then
				Anim.play("Landed")
			else
				Anim.play("LightLanded")
			end
		elseif new == Enum.HumanoidStateType.Freefall then
			State.isAirborne = true
			task.delay(0.35, function()
				if Humanoid:GetState() == Enum.HumanoidStateType.Freefall then
					Anim.play("Fall")
				end
			end)
		elseif new == Enum.HumanoidStateType.Running then
			State.isAirborne = false
			Anim.stop("Fall", 0.1)
		end
	end)


	-- Dash


	local DASH_CD    = 3
	local DASH_SPEED = 150
	local dashOnCD   = false

	local function performDash(animName, velocity)
		Anim.stopAll(0.1)
		State.isDashing = true
		Anim.play(animName)
		local bv = Instance.new("BodyVelocity")
		bv.MaxForce = Vector3.new(1e5, 0, 1e5)
		bv.Velocity = velocity
		bv.Parent   = HRP
		Debris:AddItem(bv, 0.3)
		task.delay(0.5, function()
			Anim.stop(animName)
			State.isDashing = false
		end)
	end


	-- Slide


	local SLIDE_SPEED    = 70
	local SLIDE_DURATION = 1.2
	local isSliding      = false

	local function stopSlide()
		isSliding = false
		Anim.stop("Slide1"); Anim.stop("Slide2")
		State.isSliding = false
		Humanoid.WalkSpeed = State.speed
	end


	-- Vault


	local isVaulting  = false
	local vaultOnCD   = false

	local function doVault(animName, velocity)
		if isVaulting or vaultOnCD then return end
		isVaulting = true; vaultOnCD = true
		State.isVaulting = true
		Anim.play(animName)
		local bv = Instance.new("BodyVelocity")
		bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
		bv.Velocity = velocity
		bv.Parent   = HRP
		Debris:AddItem(bv, 0.4)
		task.delay(0.7, function()
			Anim.stop(animName)
			isVaulting = false; State.isVaulting = false
		end)
		task.delay(1.2, function() vaultOnCD = false end)
	end


	-- WallRun
	

	local wallRunSide   = nil
	local wallRunNormal = nil
	local wallRunTimer  = 0
	local wallRunAtt, wallRunAntiGrav = nil, nil

	local function destroyWallConstraints()
		if wallRunAntiGrav then wallRunAntiGrav:Destroy(); wallRunAntiGrav = nil end
		if wallRunAtt      then wallRunAtt:Destroy();      wallRunAtt = nil end
	end

	local function stopWallRun(doBreak)
		if not stateIs("wallrunning") then return end
		stateReset(); wallRunTimer = 0
		destroyWallConstraints()
		Humanoid.PlatformStand = false
		Anim.stop("WallRunLeft"); Anim.stop("WallRunRight")
		State.isWallRunning = false
		Humanoid.WalkSpeed  = State.speed
		if doBreak then breakMomentum() end
	end

	local function startWallRun(side, normal)
		if not canWallRun() then return end
		stateSet("wallrunning")
		wallRunSide = side; wallRunNormal = normal; wallRunTimer = 0
		State.isWallRunning = true
		Humanoid.PlatformStand = true

		local cur = HRP.AssemblyLinearVelocity
		HRP.AssemblyLinearVelocity = Vector3.new(cur.X, 0, cur.Z)

		wallRunAtt = Instance.new("Attachment", HRP)
		local mass = getTotalMass()
		wallRunAntiGrav = Instance.new("VectorForce")
		wallRunAntiGrav.Attachment0 = wallRunAtt
		wallRunAntiGrav.RelativeTo  = Enum.ActuatorRelativeTo.World
		wallRunAntiGrav.Force       = Vector3.new(0, workspace.Gravity * mass, 0)
		wallRunAntiGrav.Parent      = HRP

		if side == "Left" then
			Anim.play("WallRunLeft")
		else
			Anim.play("WallRunRight")
		end
	end

	-- Climb

	local climbNormal   = Vector3.new(0, 0, -1)
	local climbConn     = nil
	local climbAtt, climbAntiGrav, climbStick = nil, nil, nil

	local function destroyClimbConstraints()
		if climbConn     then climbConn:Disconnect();  climbConn = nil end
		if climbAntiGrav then climbAntiGrav:Destroy(); climbAntiGrav = nil end
		if climbStick    then climbStick:Destroy();    climbStick = nil end
		if climbAtt      then climbAtt:Destroy();      climbAtt = nil end
	end

	local function stopClimb()
		if not stateIs("climbing") then return end
		stateReset()
		destroyClimbConstraints()
		Humanoid.PlatformStand = false
		climbTrack:Stop()
		Humanoid.WalkSpeed = State.speed
		State.isClimbing   = false
	end

	local function getClimbVel()
		local up    = Vector3.new(0, 1, 0)
		local cross = climbNormal:Cross(up)
		if cross.Magnitude < 0.001 then return Vector3.zero end
		local right = cross.Unit
		local vel   = Vector3.zero
		if UIS:IsKeyDown(Enum.KeyCode.W) then vel += up    * 10 end
		if UIS:IsKeyDown(Enum.KeyCode.S) then vel -= up    * 10 end
		if UIS:IsKeyDown(Enum.KeyCode.A) then vel -= right * 6  end
		if UIS:IsKeyDown(Enum.KeyCode.D) then vel += right * 6  end
		return vel
	end

	local function startClimb(hit)
		if not canClimb() then return end
		stateSet("climbing")
		State.isClimbing = true
		climbNormal = hit.Normal

		Humanoid.WalkSpeed = 0
		HRP.AssemblyLinearVelocity = Vector3.zero
		Humanoid.PlatformStand = true

		climbAtt = Instance.new("Attachment", HRP)
		local mass = getTotalMass()

		climbAntiGrav = Instance.new("VectorForce")
		climbAntiGrav.Attachment0 = climbAtt
		climbAntiGrav.RelativeTo  = Enum.ActuatorRelativeTo.World
		climbAntiGrav.Force       = Vector3.new(0, workspace.Gravity * mass, 0)
		climbAntiGrav.Parent      = HRP

		climbStick = Instance.new("VectorForce")
		climbStick.Attachment0 = climbAtt
		climbStick.RelativeTo  = Enum.ActuatorRelativeTo.World
		climbStick.Force       = -climbNormal * (mass * 30)
		climbStick.Parent      = HRP

		climbTrack:Play()

		climbConn = RunService.Heartbeat:Connect(function()
			if not stateIs("climbing") then return end
			local wallHit = castFront()
			if wallHit then
				climbNormal      = wallHit.Normal
				climbStick.Force = -climbNormal * (getTotalMass() * 30)
				HRP.AssemblyLinearVelocity = getClimbVel()
				HRP.CFrame = CFrame.lookAt(HRP.Position, HRP.Position - climbNormal)
			else
				-- no wall ahead, reached the top
				climbTrack:Stop()
				climbUpTrack:Play()
				HRP.AssemblyLinearVelocity = (HRP.CFrame.LookVector + Vector3.new(0, 0.8, 0)).Unit * 20
				stopClimb()
			end
		end)
	end

	
	-- Heartbeat — WallRun tick + Vault detection
	

	RunService.Heartbeat:Connect(function(dt)
		-- WallRun tick
		if stateIs("wallrunning") then
			wallRunTimer += dt
			local stillOnWall = wallRunSide == "Left"
				and castDir(HRP.Position, -HRP.CFrame.RightVector)
				or  castDir(HRP.Position,  HRP.CFrame.RightVector)

			if stillOnWall then
				wallRunNormal = stillOnWall.Normal
				local perp = HRP.AssemblyLinearVelocity:Dot(-wallRunNormal)
				if perp < 2 then
					HRP.AssemblyLinearVelocity -= wallRunNormal * 3
				end
			end

			if not stillOnWall or wallRunTimer >= 3 or State.stamina <= 0 then
				stopWallRun(true)
			end

		else
			-- WallRun trigger
			if canWallRun() and State.isAirborne and State.isRunning then
				if UIS:IsKeyDown(Enum.KeyCode.D) then
					local hit = castDir(HRP.Position, -HRP.CFrame.RightVector)
					if hit then startWallRun("Left", hit.Normal) end
				elseif UIS:IsKeyDown(Enum.KeyCode.A) then
					local hit = castDir(HRP.Position,  HRP.CFrame.RightVector)
					if hit then startWallRun("Right", hit.Normal) end
				end
			end

			-- Vault detection
			if not isVaulting and not vaultOnCD and State.isRunning then
				local frontHit = castFront(3.5)
				local lowHit   = workspace:Raycast(
					HRP.Position - Vector3.new(0, 1.5, 0),
					HRP.CFrame.LookVector * 3.5,
					rayParams
				)
				if lowHit and not frontHit then
					if UIS:IsKeyDown(Enum.KeyCode.A) then
						doVault("SideVault", (HRP.CFrame.LookVector - HRP.CFrame.RightVector * 0.5).Unit * 42)
					else
						doVault("MonkeyVault", HRP.CFrame.LookVector * 42)
					end
				end
			end

			-- Climb trigger
			if canClimb() then
				local wallHit = castFront()
				if wallHit then startClimb(wallHit) end
			end
		end

		-- sync airborne state with ground check
		if State.isAirborne and isOnGround() then
			State.jumpCount = 0
			State.isAirborne = false
		end
	end)


	-- RenderStepped — Movement
	

	RunService.RenderStepped:Connect(function(dt)
		handleMovement(dt)
	end)


	-- Input


	UIS.InputBegan:Connect(function(input, gp)
		if gp then return end
		local key = input.KeyCode

		-- Sprint
		if key == Enum.KeyCode.LeftShift then
			State.isRunning = true
			Anim.stop("Walk", 0.1)
			Anim.play("AccelRun")

		-- Slide
		elseif key == Enum.KeyCode.C then
			if not isSliding and State.isRunning then
				isSliding = true; State.isSliding = true
				local anim = State.speed >= 60 and "Slide2" or "Slide1"
				Anim.play(anim)
				local bv = Instance.new("BodyVelocity")
				bv.MaxForce = Vector3.new(1e5, 0, 1e5)
				bv.Velocity = HRP.CFrame.LookVector * SLIDE_SPEED
				bv.Parent   = HRP
				Debris:AddItem(bv, 0.5)
				task.delay(SLIDE_DURATION, stopSlide)
			end

		-- Dash
		elseif key == Enum.KeyCode.Q and not dashOnCD then
			dashOnCD = true
			task.delay(DASH_CD, function() dashOnCD = false end)
			local look  = HRP.CFrame.LookVector
			local right = HRP.CFrame.RightVector
			if UIS:IsKeyDown(Enum.KeyCode.W) then
				performDash("ForwardRoll", look * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.S) then
				performDash("BackRoll", -look * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.D) then
				performDash("RightRoll", right * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.A) then
				performDash("LeftRoll", -right * DASH_SPEED)
			else
				performDash("AirDash", look * 100)
			end

		-- Space: DoubleJump / WallHop / ClimbJumpOff
		elseif key == Enum.KeyCode.Space then
			if stateIs("climbing") then
				climbTrack:Stop()
				jumpOffTrack:Play()
				HRP.AssemblyLinearVelocity = (Vector3.new(0, 1.3, 0) - climbNormal).Unit * 50
				stopClimb()

			elseif stateIs("wallrunning") then
				local normal = wallRunNormal
				stopWallRun(false)
				HRP.AssemblyLinearVelocity = (normal + Vector3.new(0, 1.4, 0)).Unit * 55

			elseif State.isAirborne and State.jumpCount >= 1 and State.jumpCount < MAX_JUMPS then
				State.jumpCount += 1
				Anim.stop("DoubleJump", 0); Anim.stop("DoubleJump2", 0)
				if State.jumpCount == 1 then
					local spd = State.speed > 20 and 65 or 45
					local bv  = Instance.new("BodyVelocity")
					bv.MaxForce = Vector3.new(1e5, 0, 1e5)
					bv.Velocity = Vector3.new(HRP.CFrame.LookVector.X * spd, 0, HRP.CFrame.LookVector.Z * spd)
					bv.Parent   = HRP
					Debris:AddItem(bv, 0.22)
					Anim.play("DoubleJump")
				else
					local jumpF = 90 + State.jumpCount * 5
					local fwd   = State.speed > 20 and 40 or 20
					local bv    = Instance.new("BodyVelocity")
					bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
					bv.Velocity = Vector3.new(
						HRP.CFrame.LookVector.X * fwd,
						jumpF,
						HRP.CFrame.LookVector.Z * fwd
					)
					bv.Parent = HRP
					Debris:AddItem(bv, 0.18)
					Anim.play(State.jumpCount % 2 == 0 and "DoubleJump2" or "DoubleJump")
				end
			elseif not State.isAirborne then
				State.jumpCount += 1
			end
		end
	end)

	UIS.InputEnded:Connect(function(input, gp)
		if gp then return end
		if input.KeyCode == Enum.KeyCode.LeftShift then
			State.isRunning = false
			if not inParkour() then breakMomentum() end
		end
	end)

	-- cleanup on respawn
	Character.AncestryChanged:Connect(function()
		if not Character:IsDescendantOf(game) then
			destroyClimbConstraints()
			destroyWallConstraints()
			initialized = false
		end
	end)
end

return ParkourSystem
