-- ServerScript > ServerScriptService

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = Instance.new("Folder")
Remotes.Name = "CombatRemotes"
Remotes.Parent = ReplicatedStorage

local function makeRemote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = Remotes
	return r
end

local RE_Attack  = makeRemote("Attack")
local RE_Dash    = makeRemote("Dash")
local RE_Slam    = makeRemote("Slam")
local RE_FX      = makeRemote("PlayFX")
local RE_HitStop = makeRemote("HitStop")

local Combat = {
	combo = { window = 0.65, maxHits = 3, damage = {12,14,22}, range = 5.5, box = Vector3.new(5,4,5.5), kb = {20,20,48} },
	dash  = { cd = 1.2, force = 92, duration = 0.17 },
	slam  = { cd = 8, damage = 55, radius = 12, upForce = 62, kb = 82 },
	iframes = 0.35,
	maxHp = 100,
}

local playerStates = {}

local function newState()
	return { combo = 0, lastCombo = 0, attackLock = false, lastDash = 0, lastSlam = 0, hitIframes = {} }
end

local function getHRP(player)
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum(player)
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function isAlive(player)
	local h = getHum(player)
	return h and h.Health > 0
end

local function inBox(cf, size, ignore)
	local half = size/2
	local hitChars = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		if not c or c == ignore then continue end
		local hrp = c:FindFirstChild("HumanoidRootPart")
		local h = c:FindFirstChildOfClass("Humanoid")
		if not hrp or not h or h.Health <=0 then continue end
		local lp = cf:PointToObjectSpace(hrp.Position)
		if math.abs(lp.X)<=half.X and math.abs(lp.Y)<=half.Y and math.abs(lp.Z)<=half.Z then
			table.insert(hitChars, c)
		end
	end
	return hitChars
end

local function applyKnockback(target, source, force)
	local dir = target.Position - source.Position
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.01 then dir = source.CFrame.LookVector end
	dir = Vector3.new(dir.X, 0.4, dir.Z).Unit
	target:ApplyImpulse(dir * force * target.AssemblyMass)
end

local function hitPlayer(victim, attacker, dmg, kb)
	local hum = victim:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health<=0 then return end
	local tRoot = victim:FindFirstChild("HumanoidRootPart")
	local sRoot = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
	hum:TakeDamage(dmg)
	if tRoot and sRoot and kb>0 then applyKnockback(tRoot,sRoot,kb) end
	RE_HitStop:FireClient(attacker,0.08)
	local vp = Players:GetPlayerFromCharacter(victim)
	if vp then RE_HitStop:FireClient(vp,0.1) end
end

local function canHit(state, id)
	local last = state.hitIframes[id]
	return not last or (tick() - last) >= Combat.iframes
end

local function addHit(state, id)
	state.hitIframes[id] = tick()
end

local function applyVel(root, vel, dur)
	local att = root:FindFirstChildOfClass("Attachment") or Instance.new("Attachment", root)
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.VectorVelocity = vel
	lv.MaxForce = 1e6
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.Parent = root
	Debris:AddItem(lv, dur)
end

local function nearGround(root, thresh)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { root.Parent }
	params.FilterType = Enum.RaycastFilterType.Exclude
	return workspace:Raycast(root.Position, Vector3.new(0, -(thresh + root.Size.Y/2),0), params) ~= nil
end

local function doCombo(player, state)
	local root = getHRP(player)
	if not root then return end
	local idx = state.combo
	local cf = root.CFrame * CFrame.new(0,0,-Combat.combo.range/2)
	for _, char in ipairs(inBox(cf, Combat.combo.box, player.Character)) do
		local vp = Players:GetPlayerFromCharacter(char)
		local id = vp and vp.UserId or char:GetDebugId()
		if canHit(state,id) then
			addHit(state,id)
			hitPlayer(char, player, Combat.combo.damage[idx], Combat.combo.kb[idx])
			local r = char:FindFirstChild("HumanoidRootPart")
			RE_FX:FireAllClients("HitSpark", r and r.Position or root.Position)
		end
	end
	RE_FX:FireAllClients("SwingTrail", root.CFrame, idx)
end

-- Attack
RE_Attack.OnServerEvent:Connect(function(player)
	if not isAlive(player) then return end
	local state = playerStates[player]
	if not state or state.attackLock then return end
	local now = tick()
	if now - state.lastCombo > Combat.combo.window then state.combo=0 end
	state.combo = (state.combo % Combat.combo.maxHits)+1
	state.lastCombo = now
	state.attackLock = true
	doCombo(player,state)
	task.delay(0.27 + (state.combo-1)*0.055, function()
		if playerStates[player] then state.attackLock=false end
	end)
end)

-- Dash
RE_Dash.OnServerEvent:Connect(function(player, dir)
	if not isAlive(player) then return end
	local state = playerStates[player]
	if not state then return end
	local now = tick()
	if now - state.lastDash < Combat.dash.cd then return end
	local root = getHRP(player)
	if not root then return end
	if typeof(dir)~="Vector3" or dir.Magnitude<0.1 then dir=root.CFrame.LookVector end
	dir = Vector3.new(dir.X,0,dir.Z).Unit
	state.lastDash = now
	applyVel(root, dir*Combat.dash.force, Combat.dash.duration)
	RE_FX:FireAllClients("DashEffect", root.Position, dir)
end)

-- Slam
RE_Slam.OnServerEvent:Connect(function(player)
	if not isAlive(player) then return end
	local state = playerStates[player]
	if not state then return end
	local now = tick()
	if now - state.lastSlam < Combat.slam.cd then return end
	local root = getHRP(player)
	if not root then return end
	state.lastSlam = now

	applyVel(root, Vector3.new(0,Combat.slam.upForce,0),0.22)
	local launchTime = tick()
	local apexConn
	apexConn = RunService.Heartbeat:Connect(function()
		if not playerStates[player] or not isAlive(player) then apexConn:Disconnect() return end
		local r = getHRP(player)
		if not r then apexConn:Disconnect() return end
		if r.AssemblyLinearVelocity.Y>1 and tick()-launchTime<0.6 then return end
		apexConn:Disconnect()

		applyVel(r, Vector3.new(0,-Combat.slam.upForce*2.4,0),0.12)
		local dropTime = tick()
		local landConn
		landConn = RunService.Heartbeat:Connect(function()
			if not playerStates[player] or not isAlive(player) then landConn:Disconnect() return end
			local lr = getHRP(player)
			if not lr then landConn:Disconnect() return end
			if not nearGround(lr,3.5) and tick()-dropTime<1.2 then return end
			landConn:Disconnect()

			local hits = inBox(CFrame.new(lr.Position), Vector3.new(Combat.slam.radius*2,6,Combat.slam.radius*2), player.Character)
			for _, char in ipairs(hits) do
				local vp = Players:GetPlayerFromCharacter(char)
				local id = vp and vp.UserId or char:GetDebugId()
				if canHit(state,id) then
					addHit(state,id)
					hitPlayer(char, player, Combat.slam.damage, Combat.slam.kb)
				end
			end
			RE_FX:FireAllClients("SlamShockwave", lr.Position)
		end)
	end)
end)

-- Player lifecycle
Players.PlayerAdded:Connect(function(player)
	playerStates[player] = newState()
	player.CharacterAdded:Connect(function(char)
		local s = playerStates[player]
		if s then s.combo=0; s.lastCombo=0; s.attackLock=false; s.hitIframes={} end
		local h = char:WaitForChild("Humanoid")
		h.MaxHealth = Combat.maxHp
		h.Health = Combat.maxHp
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)

RunService.Heartbeat:Connect(function()
	local now = tick()
	for _, s in pairs(playerStates) do
		for id, t in pairs(s.hitIframes) do
			if now - t > Combat.iframes*4 then s.hitIframes[id]=nil end
		end
	end
end)
