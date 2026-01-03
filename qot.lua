while not game:IsLoaded() do
    task.wait()
end

local players    = game:GetService('Players')
local replicated = game:GetService('ReplicatedStorage')
local run        = game:GetService('RunService')
local workspace  = game:GetService('Workspace')
local player     = players.LocalPlayer
local char       = player.Character or player.CharacterAdded:Wait()
local root       = char:WaitForChild('HumanoidRootPart')
local remote     = replicated.PlayerEvents.MultiEntityHit
local playergui  = player:WaitForChild('PlayerGui')
local entities   = workspace.SpawnedEntities
local fx         = workspace:FindFirstChild('FX')

playergui.MainGui:WaitForChild('FortunesFrame')

----------------------------------------------------------------
-- Fortune Selection
----------------------------------------------------------------
task.spawn(function()
    task.wait(1)

    local fortunes = playergui.MainGui:FindFirstChild('FortunesFrame')
    local bestn    = nil
    local bestp    = nil
    local nstars   = -math.huge
    local pstars   = math.huge

    for _, v in pairs(fortunes.Container:GetChildren()) do
        if v.Name ~= 'FortuneFrame' then
            continue
        end

        local top    = v.Container.TopFrame
        local stars  = 0

        for _, el in pairs(top.TierFrame:GetChildren()) do
            if el.Name == 'Star' then
                stars += 1
            end
        end

        if top:FindFirstChild('NegativeGradient') then
            -- most stars
            if stars > nstars then
                nstars = stars
                bestn  = v
            end

        elseif top:FindFirstChild('PositiveGradient') then
            -- least stars, if no negatives
            if stars < pstars then
                pstars = stars
                bestp  = v 
            end
        end
    end

    firesignal((bestn or bestp).TextButton.MouseButton1Click)

    task.wait(1.5)

    firesignal(fortunes:WaitForChild('ConfirmBtnFrame'):WaitForChild('Container'):WaitForChild('TextButton').MouseButton1Click)
end)


----------------------------------------------------------------
-- Character Setup
----------------------------------------------------------------
-- disable all collisions
for _, part in ipairs(char:GetDescendants()) do
    if part:IsA('BasePart') then
        part.CanCollide = false
    end
end

-- lock camera
local camera = workspace.CurrentCamera

camera.CameraType = Enum.CameraType.Scriptable

local ctarget  = nil
local autofarm = true
local dodging  = false
local dtime    = 0

----------------------------------------------------------------
-- Safety Helpers
----------------------------------------------------------------
-- checks if position is safe from aoe
local function checkifsafe(position, minDistance)
    if not fx then return true end

    for _, effect in pairs(fx:GetChildren()) do
        if effect.Name == 'Inner' and effect:IsA('MeshPart') then
            if (effect.Position - position).Magnitude < minDistance then
                return false
            end
        end
    end

    return true
end

-- finds safe position below mob
local function findsafepos(mobPos, boxSize, minSafeDist, maxAttempts)
    for i = 1, maxAttempts do
        local offset = Vector3.new(
            math.random(-boxSize, boxSize),
            math.random(-boxSize, -5),  -- always below
            math.random(-boxSize, boxSize)
        )

        if checkifsafe(mobPos + offset, minSafeDist) then
            return offset
        end
    end

    -- fallback (far away)
    return Vector3.new(
        math.random(-25, 25),
        math.random(-25, -15),
        math.random(-25, 25)
    )
end

----------------------------------------------------------------
-- Camera Tracking
----------------------------------------------------------------
run.RenderStepped:Connect(function()
    if ctarget and ctarget:FindFirstChild('HumanoidRootPart') then
        local mobRoot = ctarget.HumanoidRootPart
        local mobPos  = mobRoot.Position
        
        -- Closer camera view
        camera.CFrame = CFrame.lookAt(
            mobPos + Vector3.new(0, 10, 15),
            mobPos
        )
    end
end)

----------------------------------------------------------------
-- Heartbeat / Dodge Logic
----------------------------------------------------------------
run.Heartbeat:Connect(function()
    if autofarm and ctarget and root then
        local mroot = ctarget:FindFirstChild('HumanoidRootPart')

        if mroot then
            -- prevent physics drift
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)

            -- continuously enforce flying state
            local humanoid = char:FindFirstChild('Humanoid')

            if humanoid then
                humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
                humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
                humanoid:ChangeState(Enum.HumanoidStateType.Flying)
            end

            local curtime = tick()

            if not dodging then
                local detected = false
                local closest  = math.huge

                -- scan for danger
                if fx then
                    for _, effect in pairs(fx:GetChildren()) do
                        if effect.Name == 'Inner' and effect:IsA('MeshPart') then
                            local dist = (effect.Position - root.Position).Magnitude

                            if dist < closest then
                                closest = dist
                            end

                            -- increased detection range to 9
                            if dist < 9 then
                                detected = true
                            end
                        end
                    end
                end

                -- dodge if needed
                if detected and (curtime - dtime) > 0.2 then
                    dodging = true
                    dtime   = curtime

                    -- stricter safe position requirements
                    local safeOffset = findsafepos(mroot.Position, 25, 12, 30)

                    root.CFrame = CFrame.new(mroot.Position + safeOffset)

                    -- shorter dodge duration for faster return
                    task.spawn(function()
                        task.wait(0.5)

                        dodging = false
                    end)
                else
                    -- default position (below mob)
                    root.CFrame = CFrame.new(mroot.Position + Vector3.new(0, -13, 0))
                end
            end
        end
    end
end)

----------------------------------------------------------------
-- Auto Farm Loop - Continuous Attack
----------------------------------------------------------------
task.spawn(function()
    task.wait(2)

    while autofarm do
        local entity = nil

        -- find next alive entity
        for _, en in pairs(entities:GetChildren()) do
            local hum     = en:FindFirstChild('Humanoid')
            local mroot = en:FindFirstChild('HumanoidRootPart')

            if hum and mroot and hum.Health > 0 then
                entity = en
                break
            end
        end

        -- attack mob
        if entity then
            ctarget = entity
            local hum = entity.Humanoid

            -- attack continuously - no waiting during dodges
            while hum.Health > 0 and autofarm do
                -- attack regardless of dodge state
                remote:FireServer({ entity })

                task.wait(0.05)  -- faster attack rate
            end

            ctarget = nil
        else
            -- all mobs cleared, click play again
            task.wait(0.3)

            pcall(function()
                firesignal(
                    playergui
                        .MainGui
                        .InstanceCompleteFrame
                        .Container.Bottombar
                        .PlayAgainBtnFrame
                        .TextButton
                        .MouseButton1Click
                )
            end)

            break
        end

        task.wait(0.05)
    end
end)

-- equip weapon
replicated.PlayerEvents.ManageWeapon:InvokeServer(true)

-- queue execution
queue_on_teleport(game:HttpGet('https://raw.githubusercontent.com/kagehana/bh2/refs/heads/main/qot.lua'))
