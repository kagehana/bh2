--////////////////////////////////////////////////////////////////////
--// BOOTSTRAP & CONNECTION MANAGEMENT
--////////////////////////////////////////////////////////////////////

-- disconnect previous run connections (hot reload safety)
if _G['bhconn'] then
    for _, v in ipairs(_G['bhconn']) do
        v:Disconnect()
    end
end

_G['bhconn'] = {}

-- helper to track connections for cleanup
local function addconn(conn)
    table.insert(_G['bhconn'], conn)
end


--////////////////////////////////////////////////////////////////////
--// SERVICES
--////////////////////////////////////////////////////////////////////

local http       = game:GetService('HttpService')
local players    = game:GetService('Players')
local replicated = game:GetService('ReplicatedStorage')
local run        = game:GetService('RunService')


--////////////////////////////////////////////////////////////////////
--// UI LIBRARY
--////////////////////////////////////////////////////////////////////

-- load seoul ui library from github
local seoul  = loadstring(game:HttpGet(
    'https://github.com/kagehana/seoul/blob/main/seoul.lua?raw=true'
))()()

local window = seoul:window()


--////////////////////////////////////////////////////////////////////
--// WORLD REFERENCES
--////////////////////////////////////////////////////////////////////

local player    = players.LocalPlayer
local playergui = player:WaitForChild('PlayerGui')
local remote    = replicated.PlayerEvents.MultiEntityHit

-- workspace containers
local entities = workspace.SpawnedEntities
local npcs     = workspace:FindFirstChild('NPCs')
local qobjs    = workspace:FindFirstChild('QuestObjects')
local fx       = workspace:FindFirstChild('FX')
local respawns = workspace:FindFirstChild('RespawnPoints')
local map      = workspace:FindFirstChild('Map')


--////////////////////////////////////////////////////////////////////
--// STATE & CONFIG
--////////////////////////////////////////////////////////////////////

-- character refs
local char, root

-- combat tuning
local DISTANCE = 10  -- max attack range
local DELAY    = 0   -- delay between attacks

-- feature toggles
local henabled = false  -- kill aura
local autofarm = false  -- auto farm

-- runtime state
local savedpos      = nil  -- position before farming
local dungeon       = nil  -- selected dungeon
local ctarget = nil  -- current mob being attacked

-- dodge / timing vars
local dodging     = false
local dtime = 0
local lastatk    = 0

--////////////////////////////////////////////////////////////////////
--// CHARACTER HANDLING
--////////////////////////////////////////////////////////////////////

-- updates character references and enforces no-collision
local function updateChar()
    -- wait for character spawn
    char = player.Character or player.CharacterAdded:Wait()
    root = char:WaitForChild('HumanoidRootPart')

    -- disable collisions on all character parts
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA('BasePart') then
            part.CanCollide = false
        end
    end
end

-- initial bind
updateChar()

-- re-bind on respawn
addconn(player.CharacterAdded:Connect(updateChar))

--////////////////////////////////////////////////////////////////////
--// SAFETY & DODGE HELPERS
--////////////////////////////////////////////////////////////////////

-- checks whether a position is safe from aoe
local function checkifsafe(position, minDistance)
    if not fx then
        return true
    end

    -- scan for 'Inner' meshparts (hitboxes)
    for _, effect in pairs(fx:GetChildren()) do
        if effect.Name == 'Inner' and effect:IsA('MeshPart') then
            if (effect.Position - position).Magnitude < minDistance then
                return false
            end
        end
    end

    return true
end

-- attempts to find a safe offset around a mob
local function findsafepos(mobPos, boxSize, minSafeDist, maxAttempts)
    for _ = 1, maxAttempts do
        -- generate random offset within box
        local offset = Vector3.new(
            math.random(-boxSize, boxSize),
            math.random(-boxSize, -5),  -- always negative y
            math.random(-boxSize, boxSize)
        )

        -- check if this position is safe
        if checkifsafe(mobPos + offset, minSafeDist) then
            return offset
        end
    end

    -- fallback offset (far away)
    return Vector3.new(
        math.random(-25, 25),
        math.random(-25, -15),
        math.random(-25, 25)
    )
end

--////////////////////////////////////////////////////////////////////
--// MAIN HEARTBEAT LOOP
--////////////////////////////////////////////////////////////////////
addconn(run.Heartbeat:Connect(function()
    ------------------------------------------------------------------
    -- Kill Aura Logic
    ------------------------------------------------------------------
    if henabled and root then
        local curtime = tick()

        -- attack delay throttle
        if curtime - lastatk < DELAY then
            return
        end

        local closest = nil
        local cdist   = DISTANCE

        -- find closest valid entity within range
        for _, entity in pairs(entities:GetChildren()) do
            if not entity.Name:find('Horse') then
                local hrp = entity:FindFirstChild('HumanoidRootPart')

                if hrp then
                    local dist = (root.Position - hrp.Position).Magnitude

                    if dist < cdist then
                        closest = entity
                        cdist   = dist
                    end
                end
            end
        end

        -- fire hit remote if target found
        if closest then
            remote:FireServer({ closest })

            lastatk = curtime
        end
    end


    ------------------------------------------------------------------
    -- Autofarm Positioning / Dodge Logic
    ------------------------------------------------------------------
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
                local closest    = math.huge

                -- scan for nearby danger effects
                if fx then
                    for _, effect in pairs(fx:GetChildren()) do
                        if effect.Name == 'Inner' and effect:IsA('MeshPart') then
                            local dist = (effect.Position - root.Position).Magnitude

                            if dist < closest then
                                closest = dist
                            end

                            -- trigger dodge if within 9 studs
                            if dist < 9 then
                                detected = true
                            end
                        end
                    end
                end

                -- dodge if danger detected and cooldown passed
                if detected and (curtime - dtime) > 0.2 then
                    dodging     = true
                    dtime = curtime

                    -- find safe position below mob with stricter requirements
                    local safeOffset = findsafepos(
                        mroot.Position,
                        25,  -- box size
                        12,  -- min safe distance
                        30   -- max attempts
                    )

                    -- teleport to safe position
                    root.CFrame = CFrame.new(mroot.Position + safeOffset)

                    -- shorter dodge duration for faster return
                    task.spawn(function()
                        task.wait(0.5)
                        dodging = false
                    end)

                -- default hover position (13 studs below mob)
                else
                    root.CFrame = CFrame.new(
                        mroot.Position + Vector3.new(0, -13, 0)
                    )
                end
            end
        end
    end
end))

--////////////////////////////////////////////////////////////////////
--// UI : COMBAT
--////////////////////////////////////////////////////////////////////

local combat = window:folder('Combat')

-- kill aura toggle
combat:toggle({
    name = 'Kill Aura',
    call = function(state)
        henabled = state
        seoul:notify(
            state and 'Kill aura enabled!' or 'Kill aura disabled!'
        )
    end
})

-- attack distance slider
combat:slider({
    name = 'Attack Distance',
    min  = 10,
    max  = 500,
    init = 200,
    call = function(value)
        DISTANCE = value
    end
})

-- attack delay slider
combat:slider({
    name = 'Attack Delay',
    min  = 0,
    max  = 1,
    init = 0.1,
    call = function(value)
        DELAY = value
    end
})

--////////////////////////////////////////////////////////////////////
--// UI : TELEPORTS
--////////////////////////////////////////////////////////////////////

local teleports = window:folder('Teleports')


--====================================================================
--// QUEST OBJECTS
--====================================================================
if qobjs then
    local qobjl = {}  -- list of quest object names
    local qobjr = {}  -- map of name -> cframe

    -- populate initial list
    for _, o in ipairs(qobjs:GetChildren()) do
        if o:IsA('Model') then
            table.insert(qobjl, o.Name)
            qobjr[o.Name] = o:GetPivot()
        end
    end

    table.sort(qobjl)

    local qdropd = teleports:dropdown({
        name     = 'Quest Objects',
        elements = qobjl,
        call     = function(value)
            root.CFrame = qobjr[value]
        end
    })

    -- update list when quest objects are added/removed
    local function updateql()
        local newqobjl = {}
        local newqobjr = {}

        for _, o in pairs(qobjs:GetChildren()) do
            if o:IsA('Model') then
                table.insert(newqobjl, o.Name)

                newqobjr[o.Name] = o:GetPivot()
            end
        end

        table.sort(newqobjl)
        
        -- only update if changed
        if #newqobjl ~= #qobjl then
            qobjl = newqobjl
            qobjr = newqobjr

            qdropd:modify({ elements = qobjl })
        end
    end

    addconn(qobjs.ChildAdded:Connect(updateql))
    addconn(qobjs.ChildRemoved:Connect(updateql))
end


--====================================================================
--// NPC TELEPORTS
--====================================================================
if npcs then
    local npcl = {}  -- list of npc names
    local npcr = {}  -- map of name -> cframe

    for _, npc in ipairs(npcs:GetChildren()) do
        table.insert(npcl, npc.Name)

        npcr[npc.Name] = npc:GetPivot()
    end

    table.sort(npcl)

    teleports:dropdown({
        name     = 'NPCs',
        elements = npcl,
        call     = function(value)
            root.CFrame = npcr[value]
        end
    })
end


--====================================================================
--// DUNGEON TELEPORTS
--====================================================================
local dungeonl = {}  -- list of dungeon references

for _, dg in ipairs(map:GetChildren()) do
    if dg.Name:find('Dungeon') then
        table.insert(dungeonl, dg.Name)

        dungeonl[dg.Name] = dg:GetPivot()
    end
end

table.sort(dungeonl)

teleports:dropdown({
    name     = 'Dungeons',
    elements = dungeonl,
    call     = function(value)
        root.CFrame = dungeonl[value]
    end
})


--====================================================================
--// CHESTS
--====================================================================
if fx then
    local chestl = {}  -- list of chest ids
    local chestr = {}  -- map of id -> cframe

    -- populate initial list
    for i, f in pairs(fx:GetChildren()) do
        if f.Name == 'Chest' then
            local id = f.Name .. ' #' .. i

            table.insert(chestl, id)

            chestr[id] = f:GetPivot()
        end
    end

    table.sort(chestl)

    local cdropd = teleports:dropdown({
        name     = 'Chests',
        elements = chestl,
        call     = function(value)
            root.CFrame = chestr[value]
        end
    })

    -- update list when chests spawn/despawn
    local function updatecl()
        local newchestl = {}
        local newchestr = {}

        for i, f in pairs(fx:GetChildren()) do
            if f.Name == 'Chest' then
                local id = f.Name .. ' #' .. i

                table.insert(newchestl, id)

                newchestr[id] = f:GetPivot()
            end
        end

        table.sort(newchestl)
        
        -- only update if changed
        if #newchestl ~= #chestl then
            chestl = newchestl
            chestr = newchestr

            cdropd:modify({ elements = chestl })
        end
    end

    addconn(fx.ChildAdded:Connect(updatecl))
    addconn(fx.ChildRemoved:Connect(updatecl))
end


--====================================================================
--// RESPAWN POINTS
--====================================================================
if respawns then
    local spawnl = {}  -- list of spawn point names
    local spawnr = {}  -- map of name -> object

    for _, spawn in ipairs(respawns:GetChildren()) do
        table.insert(spawnl, spawn.Name)

        spawnr[spawn.Name] = spawn
    end

    table.sort(spawnl)

    teleports:dropdown({
        name     = 'Respawn Points',
        elements = spawnl,
        call     = function(value)
            root.CFrame = spawnr[value]:GetPivot()
        end
    })


    ------------------------------------------------------------------
    -- Utility
    ------------------------------------------------------------------
    teleports:divider('Utility')

    teleports:button({
        name = 'Unlock All Respawn Points',
        call = function()
            -- lock camera above player
            local camera = workspace.CurrentCamera
            camera.CameraType = Enum.CameraType.Scriptable

            local function OnRenderStep()
                local pivpos = char:GetPivot().Position

                -- camera just above player's head (5 studs up)
                camera.CFrame = CFrame.lookAt(
                    pivpos + Vector3.new(0, 5, 0.5),
                    pivpos
                )
            end

            local runc = run.RenderStepped:Connect(OnRenderStep)

            -- iterate through all spawn points
            for _, v in pairs(spawnr) do
                root.CFrame = v:GetPivot()

                -- interact with proximity prompt
                keypress(0x45)

                task.wait(0.4)

                keyrelease(0x45)
                keypress(0x45)

                task.wait(v['Cube.005'].ProximityPrompt.HoldDuration + 0.7)

                keyrelease(0x45)

                seoul:notify('Unlocked "' .. v.Name .. '" respawn point!')
            end

            -- restore camera
            camera.CameraType = Enum.CameraType.Custom
            runc:Disconnect()
        end
    })
end

teleports:button({
    name = 'Force Main Menu',
    call = function()
        game:GetService('TeleportService'):Teleport(
            5803093656,
            player
        )
    end
})

--////////////////////////////////////////////////////////////////////
--// UI : AUTOMATION
--////////////////////////////////////////////////////////////////////

local automation = window:folder('Automation')


--====================================================================
--// AUTO FARM
--====================================================================
automation:toggle({
    name = 'Auto Farm',
    call = function(state)
        autofarm = state

        ----------------------------------------------------------------
        -- Enable Auto Farm
        ----------------------------------------------------------------
        if state then
            -- save current position for later
            savedpos = root.CFrame

            -- equip weapon
            replicated.PlayerEvents.ManageWeapon:InvokeServer(true)

            seoul:notify('Auto farm started!')

            -- enforce no-collision on character
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA('BasePart') then
                    part.CanCollide = false
                end
            end

            -- lock humanoid states (prevent falling/ragdoll)
            local humanoid = char:FindFirstChild('Humanoid')

            if humanoid then
                humanoid:SetStateEnabled(
                    Enum.HumanoidStateType.FallingDown,
                    false
                )

                humanoid:SetStateEnabled(
                    Enum.HumanoidStateType.Freefall,
                    false
                )

                humanoid:ChangeState(
                    Enum.HumanoidStateType.Flying
                )
            end

            ----------------------------------------------------------------
            -- Camera Tracking
            ----------------------------------------------------------------
            local camera = workspace.CurrentCamera

            camera.CameraType = Enum.CameraType.Scriptable

            -- update camera every frame to follow mob
            local camConn = run.RenderStepped:Connect(function()
                if ctarget and ctarget:FindFirstChild('HumanoidRootPart') then
                    local mobRoot = ctarget.HumanoidRootPart
                    local mobPos  = mobRoot.Position
                    
                    -- closer camera view
                    camera.CFrame = CFrame.lookAt(
                        mobPos + Vector3.new(0, 10, 15),
                        mobPos
                    )
                end
            end)

            addconn(camConn)

            ----------------------------------------------------------------
            -- Target Selection & Continuous Attack
            ----------------------------------------------------------------
            task.spawn(function()
                while autofarm do
                    local entity = nil

                    -- find next alive entity
                    for _, en in pairs(entities:GetChildren()) do
                        local hum   = en:FindFirstChild('Humanoid')
                        local mroot = en:FindFirstChild('HumanoidRootPart')

                        if hum and mroot and hum.Health > 0 then
                            entity = en
                            break
                        end
                    end

                    -- engage target
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

                    -- no targets remaining
                    else
                        -- return to saved position
                        if savedpos then
                            root.CFrame = savedpos
                        end

                        seoul:notify('All mobs cleared!')

                        autofarm = false

                        break
                    end
                end
            end)

        ----------------------------------------------------------------
        -- Disable Auto Farm
        ----------------------------------------------------------------
        else
            seoul:notify('Auto farm stopped!')

            ctarget = nil

            -- return to saved position
            if savedpos then
                root.CFrame = savedpos
            end

            -- restore camera
            workspace.CurrentCamera.CameraType = Enum.CameraType.Custom

            -- restore humanoid states
            local humanoid = char:FindFirstChild('Humanoid')

            if humanoid then
                humanoid:SetStateEnabled(
                    Enum.HumanoidStateType.FallingDown,
                    true
                )

                humanoid:SetStateEnabled(
                    Enum.HumanoidStateType.Freefall,
                    true
                )

                humanoid:ChangeState(
                    Enum.HumanoidStateType.GettingUp
                )
            end

            -- restore collisions
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA('BasePart') then
                    part.CanCollide = true
                end
            end
        end
    end
})

--====================================================================
--// AUTO PLAY
--====================================================================
automation:button({
    name = 'Auto Play',
    call = function()
        ----------------------------------------------------------------
        -- Queue Execution
        ----------------------------------------------------------------
        queue_on_teleport(game:HttpGet('https://raw.githubusercontent.com/kagehana/bh2/refs/heads/main/qot.lua'))

        -- notify player that they need to enter a dungeon
        seoul:notify('Ok, enter a dungeon!')
    end
})



--////////////////////////////////////////////////////////////////////
--// FINALIZE UI
--////////////////////////////////////////////////////////////////////

window:ready()
