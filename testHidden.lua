--[[
	ParkourSystem.lua
	A client-side LocalScript module implementing a full parkour controller for Roblox.

	Features:
	  • Accelerating sprint with momentum-based speed curve
	  • Stamina system (drains while running/in parkour, regenerates at rest)
	  • Double/multi-jump with distinct animations per jump count
	  • Directional air dash with cooldown
	  • Slide with speed-based animation variants
	  • Ledge vault (monkey vault & side vault) via low-ray detection
	  • Wall running (left & right) with anti-gravity constraint
	  • Wall climbing with directional input and auto-ledge-grab

	All physics use the modern Roblox constraint API:
	  LinearVelocity, VectorForce via Attachments (BodyVelocity is deprecated).

	Author: devrobloxm
]]

local ParkourSystem = {}

-- ─── Services ──────────────────────────────────────────────────────────────────
local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

-- Animation and resource folder expected in ReplicatedStorage
local ResourceFolder = game.ReplicatedStorage:WaitForChild("Resource")

-- ─── Runtime State ─────────────────────────────────────────────────────────────
--[[
	State table holds mutable per-session values shared across all sub-systems.
	It is reset implicitly when the module re-initialises after character respawn.
]]
local State = {
	currentSpeed  = 16,   -- current WalkSpeed value, rises during sprint
	stamina       = 100,  -- 0–100; gated resource for running and parkour actions
	hasMomentum   = false,-- true when speed has hit the maximum sprint cap
	isRunning     = false,-- shift held and moving
	isDashing     = false,
	isWallRunning = false,
	isClimbing    = false,
	isVaulting    = false,
	isSliding     = false,
	isAirborne    = false,
	jumpCount     = 0,    -- how many jumps used in the current airborne phase
}

-- ─── Parkour State Machine ─────────────────────────────────────────────────────
--[[
	A simple string-based state machine ensures mutually exclusive parkour states.
	Only one of: "idle" | "climbing" | "wallrunning" | "dashing" | "sliding" | "vaulting"
	can be active at a time, preventing conflicting physics forces.
]]
local parkourState = "idle"

local function GetState()    return parkourState end
local function SetState(s)   parkourState = s end
local function ResetState()  parkourState = "idle" end
local function IsState(s)    return parkourState == s end

-- Returns true when ANY special movement is active (used to suppress normal movement logic)
local function IsInParkour()
	return State.isWallRunning or State.isClimbing
		or State.isVaulting    or State.isDashing
		or State.isSliding
end

-- Strips momentum and returns speed to the base walk value
local function BreakMomentum()
	State.hasMomentum  = false
	State.currentSpeed = 16
end

-- ─── Stamina Constants ─────────────────────────────────────────────────────────
local STAMINA_MAX          = 100
local STAMINA_DRAIN_SLOW   = 2   -- drain rate while at full momentum (efficient running)
local STAMINA_DRAIN_GROUND = 8   -- drain rate during normal sprint
local STAMINA_DRAIN_PARKOUR = 15 -- drain rate during wall-run / climb / etc.
local STAMINA_REGEN_RATE   = 4   -- regen rate while idle or walking

-- Called every RenderStepped frame; adjusts stamina based on current activity
local function UpdateStamina(deltaTime)
	if State.isRunning or IsInParkour() then
		-- Choose drain tier: momentum running is cheapest, active parkour is most expensive
		local drainRate
		if State.hasMomentum then
			drainRate = STAMINA_DRAIN_SLOW
		elseif IsInParkour() then
			drainRate = STAMINA_DRAIN_PARKOUR
		else
			drainRate = STAMINA_DRAIN_GROUND
		end
		State.stamina = math.clamp(State.stamina - drainRate * deltaTime, 0, STAMINA_MAX)
	else
		State.stamina = math.clamp(State.stamina + STAMINA_REGEN_RATE * deltaTime, 0, STAMINA_MAX)
	end

	-- If stamina empties mid-action, kill momentum so speed decelerates naturally
	if State.stamina <= 0 then
		BreakMomentum()
	end
end

-- ─── Animation Controller ──────────────────────────────────────────────────────
--[[
	The Anim module manages animation tracks via a priority system.
	Higher-priority animations override lower ones.
	"Transient" animations (rolls, landings, jumps) play once and are not tracked
	as the "current" looping anim, allowing the base layer to resume afterwards.
]]

-- Numeric priority — higher value wins over lower; equal priority allows swap
local ANIM_PRIORITY = {
	Idle           = 0,
	Walk           = 1,
	AccelRun       = 2,
	Sprint         = 3,
	Fall           = 2,
	Slide1         = 4,
	Slide2         = 4,
	WallRunLeft    = 5,
	WallRunRight   = 5,
	Climb          = 5,
	ClimbUp        = 6,
	DoubleJump     = 6,
	DoubleJump2    = 6,
	LightLanded    = 5,
	Landed         = 6,
	ClimbJumpOff   = 7,
	WallHopLeft    = 7,
	WallHopRight   = 7,
	MonkeyVault    = 7,
	SideVault      = 7,
	ForwardRoll    = 8,
	BackRoll       = 8,
	LeftRoll       = 8,
	RightRoll      = 8,
	AirDash        = 8,
}

--[[
	Transient animations play once and then return control to the current base anim.
	They do NOT update `currentAnimName` so the base layer resumes automatically.
]]
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

local animationTracks    = {}   -- name → AnimationTrack
local currentAnimName    = nil  -- name of the active base-layer animation
local currentAnimPriority = -1  -- priority level of currentAnimName
local lockedAnimSet      = {}   -- when non-empty, only these anims may play

local Anim = {}

-- Register a loaded AnimationTrack under a given name
function Anim.Register(name, track)
	animationTracks[name] = track
end

-- Restrict playback to a whitelist of animation names (e.g. during climb)
function Anim.LockTo(nameList)
	lockedAnimSet = {}
	for _, animName in ipairs(nameList) do
		lockedAnimSet[animName] = true
	end
end

-- Remove any playback restriction
function Anim.Unlock()
	lockedAnimSet = {}
end

-- Play an animation by name, respecting priority and lock rules
function Anim.Play(name, fadeInTime)
	local track = animationTracks[name]
	if not track then return end -- silently skip unknown anims

	-- Respect the lock whitelist if one is active
	if next(lockedAnimSet) and not lockedAnimSet[name] then return end

	local priority = ANIM_PRIORITY[name] or 0

	-- Transient anims always play immediately; they don't affect base layer state
	if TRANSIENT_ANIMS[name] then
		if track.IsPlaying then track:Stop(0) end
		track:Play(fadeInTime or 0.1)
		return
	end

	-- Lower-priority requests are ignored while a higher one is active
	if priority < currentAnimPriority then return end

	-- Stop the previous base animation before switching
	if currentAnimName and currentAnimName ~= name then
		local oldTrack = animationTracks[currentAnimName]
		if oldTrack and oldTrack.IsPlaying then
			oldTrack:Stop(fadeInTime or 0.15)
		end
		currentAnimName     = nil
		currentAnimPriority = -1
	end

	track:Stop(0)
	track:Play(fadeInTime or 0.1)
	currentAnimName     = name
	currentAnimPriority = priority
end

-- Stop an animation by name; also clears base-layer state if it was current
function Anim.Stop(name, fadeOutTime)
	local track = animationTracks[name]
	if track and track.IsPlaying then
		track:Stop(fadeOutTime or 0.15)
	end
	if currentAnimName == name then
		currentAnimName     = nil
		currentAnimPriority = -1
	end
end

-- Stop every playing animation (used on dash / major state changes)
function Anim.StopAll(fadeOutTime)
	for _, track in pairs(animationTracks) do
		if track.IsPlaying then
			track:Stop(fadeOutTime or 0.15)
		end
	end
	currentAnimName     = nil
	currentAnimPriority = -1
end

-- Returns whether a named animation is currently playing
function Anim.IsPlaying(name)
	local track = animationTracks[name]
	return track ~= nil and track.IsPlaying
end

-- ─── Physics Helpers ───────────────────────────────────────────────────────────
--[[
	CreateLinearVelocity builds the modern equivalent of the deprecated BodyVelocity.
	It attaches a LinearVelocity constraint to an Attachment on the given BasePart,
	applies the desired velocity vector, then destroys it after `lifetime` seconds.

	LinearVelocity was introduced in Roblox's assembly physics rework and is the
	recommended replacement for BodyVelocity.
]]
local function CreateLinearVelocity(rootPart, velocityVector, lifetime, horizontalOnly)
	local attachment = Instance.new("Attachment")
	attachment.Parent = rootPart

	local constraint = Instance.new("LinearVelocity")
	constraint.Attachment0 = attachment
	constraint.RelativeTo  = Enum.ActuatorRelativeTo.World
	constraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector

	if horizontalOnly then
		-- Lock vertical axis so gravity still applies naturally (used for slides/dashes)
		constraint.MaxForce        = Vector3.new(1e5, 0, 1e5)
	else
		constraint.MaxForce        = Vector3.new(1e5, 1e5, 1e5)
	end

	constraint.VectorVelocity  = velocityVector
	constraint.Parent          = rootPart

	-- Auto-destroy after the desired duration
	Debris:AddItem(constraint, lifetime)
	Debris:AddItem(attachment, lifetime)
end

-- ─── Initialisation ────────────────────────────────────────────────────────────
local hasInitialised = false

function ParkourSystem:Init()
	if hasInitialised then return end
	hasInitialised = true

	-- ── Character references ──
	local localPlayer = Players.LocalPlayer
	local character   = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	local rootPart    = character:WaitForChild("HumanoidRootPart")
	local humanoid    = character:WaitForChild("Humanoid")
	local animator    = humanoid:WaitForChild("Animator")

	-- Disable the default Roblox Animate script so it doesn't fight our system
	local defaultAnimScript = character:FindFirstChild("Animate")
	if defaultAnimScript then
		defaultAnimScript.Enabled = false
	end

	-- Stop any tracks the default script may have started
	for _, track in pairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
	end

	-- ── Load animations ──
	-- Helper that loads an Animation instance from the resource folder and registers it
	local function LoadAndRegister(animName)
		local animInstance = ResourceFolder.Animations[animName]
		local track = animator:LoadAnimation(animInstance)
		Anim.Register(animName, track)
		return track
	end

	LoadAndRegister("Walk")
	LoadAndRegister("AccelRun")
	LoadAndRegister("Sprint")
	LoadAndRegister("Fall")
	LoadAndRegister("Landed")
	LoadAndRegister("LightLanded")
	LoadAndRegister("DoubleJump")
	LoadAndRegister("DoubleJump2")
	LoadAndRegister("ForwardRoll")
	LoadAndRegister("BackRoll")
	LoadAndRegister("LeftRoll")
	LoadAndRegister("RightRoll")
	LoadAndRegister("AirDash")
	LoadAndRegister("Slide1")
	LoadAndRegister("Slide2")
	LoadAndRegister("MonkeyVault")
	LoadAndRegister("SideVault")
	LoadAndRegister("WallRunLeft")
	LoadAndRegister("WallRunRight")

	local climbTrack   = LoadAndRegister("Climb")
	local climbUpTrack = LoadAndRegister("ClimbUp")
	local jumpOffTrack = LoadAndRegister("ClimbJumpOff")

	-- Wall-run animations are looped; the system manually stops them on exit
	animationTracks.WallRunLeft.Looped  = true
	animationTracks.WallRunRight.Looped = true
	climbTrack.Looped = true

	-- ── Raycast params ──
	-- All raycasts exclude the local character so we don't self-detect
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	--[[
		CastInDirection fires a ray from origin toward dir*distance.
		Only returns a hit if the surface normal is near-vertical (i.e. a wall),
		which is determined by the Y component being below 0.85.
	]]
	local function CastInDirection(origin, direction, distance)
		distance = distance or 3.2
		local result = workspace:Raycast(origin, direction * distance, raycastParams)
		if result and math.abs(result.Normal.Y) < 0.85 then
			return result
		end
		return nil
	end

	-- Convenience: cast directly in front of the root part
	local function CastForward(distance)
		return CastInDirection(rootPart.Position, rootPart.CFrame.LookVector, distance)
	end

	-- Ground check: short downward ray from hip height
	local function IsOnGround()
		return workspace:Raycast(rootPart.Position, Vector3.new(0, -3.5, 0), raycastParams) ~= nil
	end

	--[[
		GetTotalCharacterMass sums the AssemblyMass of every BasePart in the character.
		This is needed to calculate the exact counterforce for anti-gravity constraints,
		so the character hovers in place during wall-run and climb without floating or sinking.
	]]
	local function GetTotalCharacterMass()
		local totalMass = 0
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				totalMass += part.AssemblyMass
			end
		end
		return totalMass
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- MOVEMENT SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local WALK_SPEED       = 16
	local MAX_SPRINT_SPEED = 80
	local SPRINT_THRESHOLD = 60   -- speed above which the "Sprint" anim plays vs "AccelRun"
	local DECEL_RATE       = 40   -- studs/s² of deceleration when shift is released
	-- Speed increments applied each 0.15 s during acceleration; gives a ramp-up feel
	local ACCEL_CURVE      = { 5, 10, 15, 20, 30 }

	local isFullSprint     = false -- tracks whether Sprint anim is currently active
	local accelCurveIndex  = 1     -- current position in ACCEL_CURVE
	local accelTimer       = 0     -- accumulates time to trigger next accel step

	--[[
		HandleMovement runs every RenderStepped frame.
		It manages WalkSpeed and animation based on sprint state, speed, and stamina.
		Parkour actions bypass this function entirely to avoid conflicting forces.
	]]
	local function HandleMovement(deltaTime)
		local isMoveInputActive = humanoid.MoveDirection.Magnitude > 0

		UpdateStamina(deltaTime)

		-- Parkour actions control speed themselves; skip normal movement logic
		if IsInParkour() then
			isFullSprint = false
			accelCurveIndex = 1
			accelTimer = 0
			return
		end

		if State.isRunning and State.stamina > 0 and isMoveInputActive then
			-- ── Accelerating sprint ──
			accelTimer += deltaTime
			if accelTimer >= 0.15 and accelCurveIndex <= #ACCEL_CURVE then
				State.currentSpeed = math.min(
					State.currentSpeed + ACCEL_CURVE[accelCurveIndex],
					MAX_SPRINT_SPEED
				)
				accelCurveIndex += 1
				accelTimer = 0

				-- Reaching max speed grants momentum (cheaper stamina drain)
				if State.currentSpeed >= MAX_SPRINT_SPEED then
					State.hasMomentum = true
				end
			end

			humanoid.WalkSpeed = State.currentSpeed

			-- Switch between AccelRun and Sprint animations based on current speed
			if State.currentSpeed >= SPRINT_THRESHOLD then
				if not isFullSprint then
					isFullSprint = true
					Anim.Stop("AccelRun")
					Anim.Play("Sprint")
				end
			else
				if isFullSprint then
					isFullSprint = false
					Anim.Stop("Sprint")
					Anim.Play("AccelRun")
				elseif not Anim.IsPlaying("AccelRun") then
					Anim.Play("AccelRun")
				end
			end

		elseif State.currentSpeed > WALK_SPEED then
			-- ── Decelerating after sprint ends ──
			accelCurveIndex = 1
			accelTimer = 0

			State.currentSpeed = math.max(
				State.currentSpeed - DECEL_RATE * deltaTime,
				WALK_SPEED
			)
			humanoid.WalkSpeed = State.currentSpeed

			-- Keep matching the speed to the correct animation during decel
			if State.currentSpeed >= SPRINT_THRESHOLD then
				if not Anim.IsPlaying("Sprint") then
					Anim.Stop("AccelRun")
					Anim.Play("Sprint")
				end
			elseif State.currentSpeed > WALK_SPEED + 2 then
				if not Anim.IsPlaying("AccelRun") then
					Anim.Stop("Sprint")
					Anim.Play("AccelRun")
				end
			else
				-- Fully decelerated back to walk speed
				isFullSprint = false
				Anim.Stop("Sprint", 0.2)
				Anim.Stop("AccelRun", 0.2)
			end

		else
			-- ── At walk speed or standing still ──
			accelCurveIndex = 1
			accelTimer = 0
			isFullSprint = false
			humanoid.WalkSpeed = WALK_SPEED
			State.currentSpeed = WALK_SPEED

			Anim.Stop("AccelRun", 0.15)
			Anim.Stop("Sprint",   0.15)

			if isMoveInputActive then
				if not Anim.IsPlaying("Walk") then
					Anim.Play("Walk")
				end
			else
				Anim.Stop("Walk", 0.15)
			end
		end
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- JUMP & DOUBLE-JUMP SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local MAX_JUMP_COUNT = 8 -- max number of jumps before landing resets the count

	--[[
		StateChanged listens for Roblox's humanoid state transitions.
		Landed   → reset jump counter, play landing animation
		Freefall → begin falling; start Fall anim after a short delay (avoids pop on small drops)
		Running  → clear airborne flag when touching ground while walking
	]]
	humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Landed then
			State.jumpCount = 0
			State.isAirborne = false
			Anim.Stop("Fall",        0.1)
			Anim.Stop("DoubleJump",  0.1)
			Anim.Stop("DoubleJump2", 0.1)

			-- Heavy landing anim for high-speed arrivals, light for slow ones
			if State.currentSpeed >= 60 then
				Anim.Play("Landed")
			else
				Anim.Play("LightLanded")
			end

		elseif newState == Enum.HumanoidStateType.Freefall then
			State.isAirborne = true
			-- Small delay prevents Fall anim flashing during a regular jump apex
			task.delay(0.35, function()
				if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
					Anim.Play("Fall")
				end
			end)

		elseif newState == Enum.HumanoidStateType.Running then
			State.isAirborne = false
			Anim.Stop("Fall", 0.1)
		end
	end)

	-- ────────────────────────────────────────────────────────────────────────────
	-- DASH SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local DASH_COOLDOWN   = 3    -- seconds before dash can be used again
	local DASH_SPEED      = 150  -- impulse speed in studs/s
	local dashOnCooldown  = false

	--[[
		ExecuteDash applies a horizontal LinearVelocity impulse in the given direction,
		plays the associated animation, and clears the dashing flag after a short window.
	]]
	local function ExecuteDash(animName, velocityVector)
		Anim.StopAll(0.1)
		State.isDashing = true
		Anim.Play(animName)

		-- Horizontal-only impulse; vertical momentum is unaffected (air dashes keep fall arc)
		CreateLinearVelocity(rootPart, velocityVector, 0.3, true)

		task.delay(0.5, function()
			Anim.Stop(animName)
			State.isDashing = false
		end)
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- SLIDE SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local SLIDE_SPEED    = 70  -- forward impulse speed when slide starts
	local SLIDE_DURATION = 1.2 -- how long the slide lasts before auto-stopping
	local isSlideActive  = false

	-- Cleans up the slide state and restores normal walk speed
	local function StopSlide()
		isSlideActive    = false
		State.isSliding  = false
		Anim.Stop("Slide1")
		Anim.Stop("Slide2")
		humanoid.WalkSpeed = State.currentSpeed
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- VAULT SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local isVaultActive   = false
	local vaultOnCooldown = false

	--[[
		ExecuteVault propels the character over a low obstacle.
		A low ray + no front-wall ray detects the vaultable edge condition.
		LinearVelocity with full 3D force is used to lift slightly while moving forward.
	]]
	local function ExecuteVault(animName, velocityVector)
		if isVaultActive or vaultOnCooldown then return end
		isVaultActive    = true
		vaultOnCooldown  = true
		State.isVaulting = true

		Anim.Play(animName)
		CreateLinearVelocity(rootPart, velocityVector, 0.4, false)

		task.delay(0.7, function()
			Anim.Stop(animName)
			isVaultActive    = false
			State.isVaulting = false
		end)
		task.delay(1.2, function()
			vaultOnCooldown = false
		end)
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- WALL-RUN SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local wallRunSide       = nil   -- "Left" or "Right" — which side the wall is on
	local wallRunNormal     = nil   -- surface normal of the wall being run on
	local wallRunTimer      = 0     -- elapsed time during current wall-run
	local wallRunAttachment = nil   -- Attachment anchor for anti-gravity force
	local wallRunAntiGrav   = nil   -- VectorForce cancelling gravity during wall-run

	-- Destroys constraint instances created for wall-running
	local function DestroyWallRunConstraints()
		if wallRunAntiGrav   then wallRunAntiGrav:Destroy();   wallRunAntiGrav   = nil end
		if wallRunAttachment then wallRunAttachment:Destroy(); wallRunAttachment = nil end
	end

	--[[
		StopWallRun exits wall-run state cleanly.
		If doBreakMomentum is true (e.g. fell off the wall), speed is also reset.
	]]
	local function StopWallRun(doBreakMomentum)
		if not IsState("wallrunning") then return end
		ResetState()
		wallRunTimer = 0
		DestroyWallRunConstraints()
		humanoid.PlatformStand = false
		Anim.Stop("WallRunLeft")
		Anim.Stop("WallRunRight")
		State.isWallRunning = false
		humanoid.WalkSpeed  = State.currentSpeed
		if doBreakMomentum then BreakMomentum() end
	end

	--[[
		StartWallRun enters wall-run state on the given side.
		PlatformStand is enabled so Roblox's default physics don't fight our forces.
		An anti-gravity VectorForce exactly cancels gravity so the character runs horizontally.
	]]
	local function StartWallRun(side, surfaceNormal)
		if GetState() ~= "idle" then return end
		SetState("wallrunning")

		wallRunSide         = side
		wallRunNormal       = surfaceNormal
		wallRunTimer        = 0
		State.isWallRunning = true

		-- Flatten vertical velocity so the character doesn't rocket upward on entry
		local currentVelocity     = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)

		humanoid.PlatformStand = true

		-- Build anti-gravity: Force = mass × gravity (upward), exactly cancels gravity
		wallRunAttachment = Instance.new("Attachment")
		wallRunAttachment.Parent = rootPart

		local totalMass     = GetTotalCharacterMass()
		wallRunAntiGrav     = Instance.new("VectorForce")
		wallRunAntiGrav.Attachment0  = wallRunAttachment
		wallRunAntiGrav.RelativeTo   = Enum.ActuatorRelativeTo.World
		wallRunAntiGrav.Force        = Vector3.new(0, workspace.Gravity * totalMass, 0)
		wallRunAntiGrav.Parent       = rootPart

		if side == "Left" then
			Anim.Play("WallRunLeft")
		else
			Anim.Play("WallRunRight")
		end
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- CLIMB SYSTEM
	-- ────────────────────────────────────────────────────────────────────────────
	local climbWallNormal   = Vector3.new(0, 0, -1) -- normal of wall currently being climbed
	local climbHeartbeatConn = nil                  -- Heartbeat connection active during climb
	local climbAttachment   = nil
	local climbAntiGrav     = nil   -- VectorForce: counteracts gravity
	local climbStickForce   = nil   -- VectorForce: pushes character into wall

	-- Destroys all constraint instances created for climbing
	local function DestroyClimbConstraints()
		if climbHeartbeatConn then climbHeartbeatConn:Disconnect(); climbHeartbeatConn = nil end
		if climbAntiGrav      then climbAntiGrav:Destroy();      climbAntiGrav      = nil end
		if climbStickForce    then climbStickForce:Destroy();    climbStickForce    = nil end
		if climbAttachment    then climbAttachment:Destroy();    climbAttachment    = nil end
	end

	-- Exits climb state and restores normal physics
	local function StopClimb()
		if not IsState("climbing") then return end
		ResetState()
		DestroyClimbConstraints()
		humanoid.PlatformStand = false
		climbTrack:Stop()
		humanoid.WalkSpeed = State.currentSpeed
		State.isClimbing   = false
	end

	--[[
		GetClimbVelocity converts WASD input into a velocity vector along the wall surface.
		The wall normal is used to derive an "up" and "right" direction on the wall face,
		so the character moves relative to the wall rather than world space.
	]]
	local function GetClimbVelocity()
		local worldUp  = Vector3.new(0, 1, 0)
		local crossVec = climbWallNormal:Cross(worldUp)
		if crossVec.Magnitude < 0.001 then return Vector3.zero end

		local wallRight = crossVec.Unit
		local wallUp    = worldUp
		local resultVel = Vector3.zero

		if UIS:IsKeyDown(Enum.KeyCode.W) then resultVel += wallUp    * 10 end
		if UIS:IsKeyDown(Enum.KeyCode.S) then resultVel -= wallUp    * 10 end
		if UIS:IsKeyDown(Enum.KeyCode.A) then resultVel -= wallRight * 6  end
		if UIS:IsKeyDown(Enum.KeyCode.D) then resultVel += wallRight * 6  end

		return resultVel
	end

	--[[
		StartClimb attaches the character to a wall and begins the per-frame climb loop.
		Two VectorForces are used:
		  1. climbAntiGrav  – counteracts gravity so the character doesn't slide down
		  2. climbStickForce – pushes the character into the wall so they don't drift off
		The Heartbeat loop re-reads the wall normal each frame and updates both forces
		so the character smoothly follows curved or angled surfaces.
	]]
	local function StartClimb(hitResult)
		if GetState() ~= "idle" then return end
		SetState("climbing")

		State.isClimbing    = true
		climbWallNormal     = hitResult.Normal
		humanoid.WalkSpeed  = 0
		rootPart.AssemblyLinearVelocity = Vector3.zero
		humanoid.PlatformStand = true

		climbAttachment = Instance.new("Attachment")
		climbAttachment.Parent = rootPart

		local totalMass = GetTotalCharacterMass()

		-- Anti-gravity force: exactly cancels character weight
		climbAntiGrav = Instance.new("VectorForce")
		climbAntiGrav.Attachment0 = climbAttachment
		climbAntiGrav.RelativeTo  = Enum.ActuatorRelativeTo.World
		climbAntiGrav.Force       = Vector3.new(0, workspace.Gravity * totalMass, 0)
		climbAntiGrav.Parent      = rootPart

		-- Stick force: pushes character flush with the wall (30× mass gives firm adhesion)
		climbStickForce = Instance.new("VectorForce")
		climbStickForce.Attachment0 = climbAttachment
		climbStickForce.RelativeTo  = Enum.ActuatorRelativeTo.World
		climbStickForce.Force       = -climbWallNormal * (totalMass * 30)
		climbStickForce.Parent      = rootPart

		climbTrack:Play()

		-- Per-frame climb loop: update forces and velocity from input
		climbHeartbeatConn = RunService.Heartbeat:Connect(function()
			if not IsState("climbing") then return end

			local wallHit = CastForward()
			if wallHit then
				-- Wall is still ahead; update normal and re-apply forces
				climbWallNormal       = wallHit.Normal
				climbStickForce.Force = -climbWallNormal * (GetTotalCharacterMass() * 30)

				-- Apply input-driven velocity along the wall surface
				rootPart.AssemblyLinearVelocity = GetClimbVelocity()

				-- Face the wall each frame to keep the character aligned
				rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position - climbWallNormal)
			else
				-- No wall ahead means the character has reached the ledge top
				climbTrack:Stop()
				climbUpTrack:Play()
				-- Boost up and forward to pull the character onto the surface
				rootPart.AssemblyLinearVelocity = (HRP.CFrame.LookVector + Vector3.new(0, 0.8, 0)).Unit * 20
				StopClimb()
			end
		end)
	end

	-- ────────────────────────────────────────────────────────────────────────────
	-- HEARTBEAT LOOP — Wall-run tick + Vault & Climb triggers
	-- ────────────────────────────────────────────────────────────────────────────
	RunService.Heartbeat:Connect(function(deltaTime)

		if IsState("wallrunning") then
			-- ── Wall-run maintenance ──
			wallRunTimer += deltaTime

			-- Check whether the wall is still present on the correct side
			local wallStillPresent
			if wallRunSide == "Left" then
				wallStillPresent = CastInDirection(rootPart.Position, -rootPart.CFrame.RightVector)
			else
				wallStillPresent = CastInDirection(rootPart.Position, rootPart.CFrame.RightVector)
			end

			if wallStillPresent then
				wallRunNormal = wallStillPresent.Normal
				-- Nudge character toward the wall if they're drifting away
				local wallDrift = rootPart.AssemblyLinearVelocity:Dot(-wallRunNormal)
				if wallDrift < 2 then
					rootPart.AssemblyLinearVelocity -= wallRunNormal * 3
				end
			end

			-- Exit conditions: wall gone, time limit, or stamina depleted
			if not wallStillPresent or wallRunTimer >= 3 or State.stamina <= 0 then
				StopWallRun(true)
			end

		else
			-- ── Wall-run trigger ──
			-- Only attempt to start when airborne, sprinting, and not in another action
			if GetState() == "idle" and State.isAirborne and State.isRunning then
				if UIS:IsKeyDown(Enum.KeyCode.D) then
					local leftWallHit = CastInDirection(rootPart.Position, -rootPart.CFrame.RightVector)
					if leftWallHit then StartWallRun("Left", leftWallHit.Normal) end
				elseif UIS:IsKeyDown(Enum.KeyCode.A) then
					local rightWallHit = CastInDirection(rootPart.Position, rootPart.CFrame.RightVector)
					if rightWallHit then StartWallRun("Right", rightWallHit.Normal) end
				end
			end

			-- ── Vault trigger ──
			-- Vault triggers when a low obstacle is in front but no full-height wall blocks
			if not isVaultActive and not vaultOnCooldown and State.isRunning then
				local frontWallHit = CastForward(3.5)
				local lowObstacleHit = workspace:Raycast(
					rootPart.Position - Vector3.new(0, 1.5, 0), -- origin below hip
					rootPart.CFrame.LookVector * 3.5,
					raycastParams
				)

				-- Low obstacle detected but no blocking wall → vaultable
				if lowObstacleHit and not frontWallHit then
					if UIS:IsKeyDown(Enum.KeyCode.A) then
						ExecuteVault(
							"SideVault",
							(rootPart.CFrame.LookVector - rootPart.CFrame.RightVector * 0.5).Unit * 42
						)
					else
						ExecuteVault("MonkeyVault", rootPart.CFrame.LookVector * 42)
					end
				end
			end

			-- ── Climb trigger ──
			-- If a wall is directly ahead and we're idle, begin climbing
			if GetState() == "idle" then
				local wallAhead = CastForward()
				if wallAhead then
					StartClimb(wallAhead)
				end
			end
		end

		-- Sync ground detection with airborne flag (catches edge cases)
		if State.isAirborne and IsOnGround() then
			State.jumpCount  = 0
			State.isAirborne = false
		end
	end)

	-- ────────────────────────────────────────────────────────────────────────────
	-- RENDER LOOP — Movement update
	-- ────────────────────────────────────────────────────────────────────────────
	RunService.RenderStepped:Connect(function(deltaTime)
		HandleMovement(deltaTime)
	end)

	-- ────────────────────────────────────────────────────────────────────────────
	-- INPUT HANDLING
	-- ────────────────────────────────────────────────────────────────────────────
	UIS.InputBegan:Connect(function(input, isGameProcessed)
		if isGameProcessed then return end -- ignore input captured by GUI elements

		local key = input.KeyCode

		-- ── Sprint (LeftShift) ──
		if key == Enum.KeyCode.LeftShift then
			State.isRunning = true
			Anim.Stop("Walk", 0.1)
			Anim.Play("AccelRun")

		-- ── Slide (C) ──
		elseif key == Enum.KeyCode.C then
			if not isSlideActive and State.isRunning then
				isSlideActive   = true
				State.isSliding = true

				-- Slide2 is a more dramatic slide used at high speeds
				local slideAnimName = State.currentSpeed >= 60 and "Slide2" or "Slide1"
				Anim.Play(slideAnimName)

				-- Horizontal impulse carries the character forward during the slide
				CreateLinearVelocity(
					rootPart,
					rootPart.CFrame.LookVector * SLIDE_SPEED,
					0.5,
					true -- horizontal only; gravity still applies
				)

				task.delay(SLIDE_DURATION, StopSlide)
			end

		-- ── Dash (Q) ──
		elseif key == Enum.KeyCode.Q and not dashOnCooldown then
			dashOnCooldown = true
			task.delay(DASH_COOLDOWN, function()
				dashOnCooldown = false
			end)

			local lookDir  = rootPart.CFrame.LookVector
			local rightDir = rootPart.CFrame.RightVector

			-- Direction of dash is determined by which movement key is held
			if UIS:IsKeyDown(Enum.KeyCode.W) then
				ExecuteDash("ForwardRoll", lookDir * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.S) then
				ExecuteDash("BackRoll",   -lookDir * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.D) then
				ExecuteDash("RightRoll",   rightDir * DASH_SPEED)
			elseif UIS:IsKeyDown(Enum.KeyCode.A) then
				ExecuteDash("LeftRoll",   -rightDir * DASH_SPEED)
			else
				-- No direction held → default to a forward air dash at lower speed
				ExecuteDash("AirDash", lookDir * 100)
			end

		-- ── Jump / Double-Jump / Wall-Hop / Climb-Jump (Space) ──
		elseif key == Enum.KeyCode.Space then

			if IsState("climbing") then
				-- ── Climb jump-off ──
				-- Launch away from the wall and play the jump-off animation
				climbTrack:Stop()
				jumpOffTrack:Play()
				rootPart.AssemblyLinearVelocity =
					(Vector3.new(0, 1.3, 0) - climbWallNormal).Unit * 50
				StopClimb()

			elseif IsState("wallrunning") then
				-- ── Wall hop ──
				-- Bounce away from the wall with an upward bias
				local bounceNormal = wallRunNormal
				StopWallRun(false) -- don't break momentum; this is an intentional launch
				rootPart.AssemblyLinearVelocity =
					(bounceNormal + Vector3.new(0, 1.4, 0)).Unit * 55

			elseif State.isAirborne and State.jumpCount >= 1 and State.jumpCount < MAX_JUMP_COUNT then
				-- ── Multi-jump (double, triple, …) ──
				State.jumpCount += 1
				Anim.Stop("DoubleJump",  0)
				Anim.Stop("DoubleJump2", 0)

				if State.jumpCount == 2 then
					-- Second jump: strong horizontal boost, no vertical boost
					local horizontalSpeed = State.currentSpeed > 20 and 65 or 45
					CreateLinearVelocity(
						rootPart,
						Vector3.new(
							rootPart.CFrame.LookVector.X * horizontalSpeed,
							0,
							rootPart.CFrame.LookVector.Z * horizontalSpeed
						),
						0.22,
						true
					)
					Anim.Play("DoubleJump")
				else
					-- Third+ jump: escalating vertical boost with mild forward momentum
					local verticalForce   = 90 + State.jumpCount * 5
					local forwardStrength = State.currentSpeed > 20 and 40 or 20
					CreateLinearVelocity(
						rootPart,
						Vector3.new(
							rootPart.CFrame.LookVector.X * forwardStrength,
							verticalForce,
							rootPart.CFrame.LookVector.Z * forwardStrength
						),
						0.18,
						false
					)
					-- Alternate animation each jump for visual variety
					local jumpAnimName = State.jumpCount % 2 == 0 and "DoubleJump2" or "DoubleJump"
					Anim.Play(jumpAnimName)
				end

			elseif not State.isAirborne then
				-- Regular first jump handled by Roblox's Jump() internally;
				-- we just increment the counter so multi-jump tracks correctly
				State.jumpCount += 1
			end
		end
	end)

	UIS.InputEnded:Connect(function(input, isGameProcessed)
		if isGameProcessed then return end

		if input.KeyCode == Enum.KeyCode.LeftShift then
			State.isRunning = false
			-- Only break momentum if not mid-parkour (wall-run, etc. should preserve speed)
			if not IsInParkour() then
				BreakMomentum()
			end
		end
	end)

	-- ────────────────────────────────────────────────────────────────────────────
	-- CLEANUP ON RESPAWN
	-- ────────────────────────────────────────────────────────────────────────────
	--[[
		When the character is removed from the game (respawn), all active constraint
		instances must be destroyed to avoid memory leaks and orphaned physics objects.
		hasInitialised is reset so Init() can run again on the next character.
	]]
	character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(game) then
			DestroyClimbConstraints()
			DestroyWallRunConstraints()
			hasInitialised = false
		end
	end)
end

return ParkourSystem
