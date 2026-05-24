--!strict
-- FlashlightClient.client.lua
-- Положить в: StarterPlayer -> StarterPlayerScripts
-- Тип: LocalScript
--
-- Делает следующее:
--   1. Управляет фонариком (включить/выключить на ЛКМ или клавишу F).
--   2. Каждый кадр пускает Raycast из камеры по направлению взгляда — если попал
--      в модель Фредди в пределах конуса/дальности, шлёт сигнал на сервер.
--   3. Слушает сервер: при получении FreddyJumpscare — телепортирует камеру близко
--      к Фредди (короткий "глитч-скример") + проигрывает звук скримера.
--   4. Слушает FreddySound — проигрывает 3D-звук (смех/падение) в указанной точке.

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local Workspace          = game:GetService("Workspace")
local SoundService       = game:GetService("SoundService")

local player    = Players.LocalPlayer
local camera    = Workspace.CurrentCamera

local Remotes        = ReplicatedStorage:WaitForChild("FreddyRemotes")
local FreddySpotted  = Remotes:WaitForChild("FreddySpotted")  :: RemoteEvent
local FreddyJumpscare= Remotes:WaitForChild("FreddyJumpscare"):: RemoteEvent
local FreddySoundEv  = Remotes:WaitForChild("FreddySound")    :: RemoteEvent

-- Конфигурация клиента -------------------------------------------------------
local CONFIG = {
	FlashlightRange      = 60,    -- макс. дальность луча в шпильках
	FlashlightAngleDeg   = 18,    -- половинный угол конуса (от центра луча)
	DetectCooldown       = 1.2,   -- не спамить сервер чаще, чем раз в N секунд
	-- Имена SoundId-ов (замените на свои Asset ID в Roblox Studio).
	Sounds = {
		Jumpscare = "rbxassetid://0000000000",
		Laugh     = "rbxassetid://0000000000",
		Drop      = "rbxassetid://0000000000",
	},
}

-- Фонарик --------------------------------------------------------------------
-- Простая обёртка: создаёт SpotLight, который "прикреплён" к камере через
-- невидимую часть. Включается/выключается клавишей F или ЛКМ.

local Flashlight = {}
Flashlight.__index = Flashlight

function Flashlight.new()
	local self = setmetatable({}, Flashlight)
	-- Невидимая Part, на которой "сидит" свет. Якорим, двигаем за камерой.
	local part = Instance.new("Part")
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.Anchored   = true
	part.Name       = "FlashlightAnchor"
	part.Parent     = Workspace

	local light = Instance.new("SpotLight")
	light.Brightness = 5
	light.Range      = CONFIG.FlashlightRange
	light.Angle      = CONFIG.FlashlightAngleDeg * 2 -- SpotLight.Angle — полный конус
	light.Color      = Color3.fromRGB(255, 240, 200)
	light.Face       = Enum.NormalId.Front
	light.Shadows    = true
	light.Enabled    = false
	light.Parent     = part

	self.part  = part
	self.light = light
	self.on    = false
	return self
end

function Flashlight:setOn(state: boolean)
	self.on = state
	self.light.Enabled = state
end

function Flashlight:toggle()
	self:setOn(not self.on)
end

-- Каждый кадр совмещаем позицию/направление фонарика с камерой.
function Flashlight:syncToCamera()
	-- Front-нормаль смотрит из +Z, поэтому "перевернём" CFrame.
	self.part.CFrame = camera.CFrame * CFrame.Angles(0, math.rad(180), 0)
end

-- Forward-declare фонарика (заполним ниже).
local flashlight

-- Детекция Фредди ------------------------------------------------------------
local lastDetect = 0

-- Возвращает модель Фредди (или nil, если ещё не загружена/удалена).
local function getFreddy(): Model?
	return Workspace:FindFirstChild("Freddy") :: Model?
end

-- Логика: бросаем луч из камеры вперёд. Если попадаем в модель Фредди —
-- сообщаем серверу. Дополнительно проверяем угол: даже если Raycast не
-- попал прямо, но Фредди в конусе и без преград — тоже считаем "засветил".
local function tryDetect()
	if not flashlight.on then return end
	local freddy = getFreddy()
	if not freddy or not freddy.PrimaryPart then return end

	local now = os.clock()
	if now - lastDetect < CONFIG.DetectCooldown then return end

	local origin    = camera.CFrame.Position
	local lookDir   = camera.CFrame.LookVector
	local toFreddy  = freddy.PrimaryPart.Position - origin
	local distance  = toFreddy.Magnitude
	if distance > CONFIG.FlashlightRange then return end

	-- Угол между взглядом и направлением на Фредди.
	local dot   = lookDir:Dot(toFreddy.Unit)
	local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
	if angle > CONFIG.FlashlightAngleDeg then return end

	-- Прямой Raycast — нужно убедиться, что между нами и Фредди нет стены.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, flashlight.part }
	local hit = Workspace:Raycast(origin, toFreddy.Unit * (distance + 1), params)
	if hit and hit.Instance:IsDescendantOf(freddy) then
		lastDetect = now
		-- Сервер сам перепроверит и решит, был ли это "честный" спот.
		FreddySpotted:FireServer()
	end
end

-- Звуки ----------------------------------------------------------------------
-- Универсальная функция: проиграть 3D-звук в указанной точке мира.
local function playSoundAt(soundId: string, position: Vector3, volume: number?)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Position = position
	part.Parent = Workspace

	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume  = volume or 1
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.EmitterSize = 5
	s.MaxDistance = 200
	s.Parent = part
	s:Play()
	s.Ended:Connect(function()
		part:Destroy()
	end)
end

-- Скример: коротко двигаем камеру вплотную к Фредди.
local function playJumpscare(freddyPos: Vector3, distance: number)
	-- Берём управление над камерой ненадолго.
	local oldType = camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable

	-- Звук скримера — без 3D, прямо в SoundService.
	local s = Instance.new("Sound")
	s.SoundId = CONFIG.Sounds.Jumpscare
	s.Volume = 2
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)

	-- "Глитч"-эффект: 4 кадра дёрганной камеры рядом с Фредди.
	local startTime = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - startTime
		if t > 0.45 then
			conn:Disconnect()
			camera.CameraType = oldType
			return
		end
		-- Случайный мелкий джиттер для "глитч"-ощущения.
		local jitter = Vector3.new(
			(math.random() - 0.5) * 0.5,
			(math.random() - 0.5) * 0.5,
			(math.random() - 0.5) * 0.5
		)
		local pos = freddyPos + (camera.CFrame.LookVector * -distance) + jitter
		camera.CFrame = CFrame.lookAt(pos, freddyPos)
	end)
end

-- Запуск ---------------------------------------------------------------------
flashlight = Flashlight.new()

-- Ввод: F переключает, ЛКМ-удержание включает (как в JoC).
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.F then
		flashlight:toggle()
	end
end)

-- Каждый кадр: синхронизируем фонарик с камерой и пытаемся "засветить" Фредди.
RunService.RenderStepped:Connect(function()
	flashlight:syncToCamera()
	tryDetect()
end)

-- Серверные события ----------------------------------------------------------
FreddyJumpscare.OnClientEvent:Connect(function(freddyPos: Vector3, distance: number)
	playJumpscare(freddyPos, distance)
end)

FreddySoundEv.OnClientEvent:Connect(function(soundType: string, position: Vector3)
	local id = CONFIG.Sounds[soundType]
	if id then
		playSoundAt(id, position, 1.5)
	end
end)
