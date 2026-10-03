-- Freecam for AhaSR (/lua freecam.lua)
-- Insert / F10 / Home : toggle freecam
-- F6           : slow motion, cycles 1x -> 0.5x -> 0.25x -> 0.1x -> frozen -> back to normal
--                (works with or without freecam; freecam keeps moving at full speed)
-- F8           : status popup (which hooks attached, which cameras, what was disabled)
-- F9           : camera + component dump popup
-- Move: WASD   Up/Down: E,Q or PageUp,PageDown   Fast: Shift   Slow: Ctrl
-- Look: hold Right Mouse, or arrow keys
--
-- Sent as ONE chunk with other scripts: no top-level `return`, risky calls in pcall.

local util = require("xlua.util")
local U = CS.UnityEngine

-- popups are modal (blur + the game resets the camera when they close)
local LOAD_POPUP = false

-- every /lua run starts a NEW loop; older copies stop themselves
_G.__FC_GEN = (_G.__FC_GEN or 0) + 1
local MY_GEN = _G.__FC_GEN

local NORMAL_KEYS = { "F10", "Insert", "Home" }
local HARD_KEYS = {}
local BASE_PATTERNS = { "Cinemachine", "Brain", "Animator" }
local HARD_PATTERNS = { "Cinemachine", "Brain", "Animator", "PipelineCameraEngine" }

-- helpers
local function popup(text)
    pcall(function()
        CS.RPG.Client.ConfirmDialogUtil.ShowCustomOkCancelHint(text, nil)
    end)
end

local function matchAny(s, list)
    for _, p in ipairs(list) do
        if s:find(p, 1, true) then return true end
    end
    return false
end

local function keyDown(names)
    for _, n in ipairs(names) do
        local ok, v = pcall(function() return U.Input.GetKeyDown(U.KeyCode[n]) end)
        if ok and v then return true end
    end
    return false
end

local function key(n)
    local ok, v = pcall(function() return U.Input.GetKey(U.KeyCode[n]) end)
    return ok and v or false
end

local function isRenderCam(cam)
    if not cam or not cam.enabled then return false end
    if cam.targetTexture ~= nil then return false end
    local n = cam.name:lower()
    if n:find("^ui") ~= nil then return false end
    return true
end

-- state
local enabled = false
local hard = false
local patterns = BASE_PATTERNS
local pos = U.Vector3.zero
local pitch, yaw = 0, 0
local rot = U.Quaternion.identity
local controlled = {}      -- instanceID -> camera
local disabledComps = {}   -- components we switched off, to restore later
local controlledNames = {}
local disabledNames = {}
local hooks = {}           -- attached hooks: { name=, remove=function }

-- PipelineCameraEngine is the game's own camera driver. It has a built-in pause
-- counter (PauseLateUpdateCount); the game raises it while a dialog is open, which is
-- why the camera was free while the popup was showing. We raise it ourselves.
local engines = {}   -- instanceID -> component

local function pauseEngine(c)
    local id = c:GetInstanceID()
    pcall(function()
        if engines[id] == nil then
            engines[id] = c
            c.PauseLateUpdateCount = c.PauseLateUpdateCount + 1
        elseif c.PauseLateUpdateCount == 0 then
            c.PauseLateUpdateCount = 1  -- the game cleared it; put it back
        end
    end)
end

local function resumeEngines()
    for _, c in pairs(engines) do
        pcall(function()
            if c.PauseLateUpdateCount > 0 then
                c.PauseLateUpdateCount = c.PauseLateUpdateCount - 1
            end
        end)
    end
    engines = {}
end

local function disableDrivers(cam)
    local t = cam.transform
    for _ = 1, 5 do -- camera + up to 4 parents
        if t == nil then break end
        local ok, comps = pcall(function()
            return t.gameObject:GetComponents(typeof(U.Behaviour))
        end)
        if ok and comps then
            for i = 0, comps.Length - 1 do
                local c = comps[i]
                if c and c.enabled then
                    local tn = c:GetType().Name
                    if tn == "PipelineCameraEngine" then
                        pauseEngine(c)
                    elseif matchAny(tn, patterns) then
                        c.enabled = false
                        table.insert(disabledComps, c)
                        table.insert(disabledNames, t.gameObject.name .. "/" .. tn)
                    end
                end
            end
        end
        t = t.parent
    end
end

local function scanCameras()
    for id, cam in pairs(controlled) do
        local ok = pcall(function() return cam.enabled end)
        if not ok then controlled[id] = nil end
    end
    local cams = U.Camera.allCameras
    for i = 0, cams.Length - 1 do
        local cam = cams[i]
        if isRenderCam(cam) then
            local id = cam:GetInstanceID()
            if not controlled[id] then
                controlled[id] = cam
                table.insert(controlledNames, cam.name)
            end
            disableDrivers(cam)
        end
    end
end

-- late hooks: write the camera right before it renders
-- slow motion: drives Time.timeScale. Freecam movement uses unscaledDeltaTime, so
-- the camera stays at full speed even when the game is slowed or frozen.
local SPEEDS = { 1, 0.5, 0.25, 0.1, 0 }
local speedIdx = 1
local savedScale = 1

local function applySlowmo()
    if speedIdx ~= 1 then
        pcall(function() U.Time.timeScale = SPEEDS[speedIdx] end)
    end
end

local function cycleSlowmo()
    if speedIdx == 1 then
        -- remember what the game (1x / 2x battle speed) was using
        local ok, v = pcall(function() return U.Time.timeScale end)
        savedScale = (ok and v and v > 0) and v or 1
    end
    speedIdx = speedIdx % #SPEEDS + 1
    if speedIdx == 1 then
        pcall(function() U.Time.timeScale = savedScale end)
    else
        applySlowmo()
    end
end

local function resetSlowmo()
    if speedIdx ~= 1 then
        speedIdx = 1
        pcall(function() U.Time.timeScale = savedScale end)
    end
end

local function applyTo(cam)
    pcall(function()
        local t = cam.transform
        t.position = pos
        t.rotation = rot
    end)
end

local function applyAll()
    applySlowmo()
    if not enabled then return end
    for _, cam in pairs(controlled) do applyTo(cam) end
end

local function onPreCull(cam)
    if not enabled then return end
    if cam and controlled[cam:GetInstanceID()] then applyTo(cam) end
end

local function onBeginCamera(ctx, cam)
    if not enabled then return end
    if cam and controlled[cam:GetInstanceID()] then applyTo(cam) end
end

local function tryHook(name, forms)
    -- forms: list of { add = fn, remove = fn }; the first one that works is kept
    for _, f in ipairs(forms) do
        if pcall(f.add) then
            table.insert(hooks, { name = name, remove = f.remove })
            return
        end
    end
end

local function attachHooks()
    local A = U.Application
    tryHook("Application.onBeforeRender", {
        { add = function() A.onBeforeRender('+', applyAll) end,
          remove = function() A.onBeforeRender('-', applyAll) end },
        { add = function() A.onBeforeRender = A.onBeforeRender + applyAll end,
          remove = function() A.onBeforeRender = A.onBeforeRender - applyAll end },
    })
    local C = U.Camera
    tryHook("Camera.onPreCull", {
        { add = function() C.onPreCull = C.onPreCull + onPreCull end,
          remove = function() C.onPreCull = C.onPreCull - onPreCull end },
        { add = function() C.onPreCull('+', onPreCull) end,
          remove = function() C.onPreCull('-', onPreCull) end },
    })
    local R = U.Rendering.RenderPipelineManager
    tryHook("RenderPipeline.beginCameraRendering", {
        { add = function() R.beginCameraRendering('+', onBeginCamera) end,
          remove = function() R.beginCameraRendering('-', onBeginCamera) end },
        { add = function() R.beginCameraRendering = R.beginCameraRendering + onBeginCamera end,
          remove = function() R.beginCameraRendering = R.beginCameraRendering - onBeginCamera end },
    })
end

local function detachHooks()
    for _, h in ipairs(hooks) do pcall(h.remove) end
    hooks = {}
end

-- enable / disable / status / dump
local function enable(isHard)
    hard = isHard
    patterns = isHard and HARD_PATTERNS or BASE_PATTERNS
    local main = U.Camera.main
    if main == nil then
        local cams = U.Camera.allCameras
        for i = 0, cams.Length - 1 do
            if isRenderCam(cams[i]) then main = cams[i] break end
        end
    end
    if main then
        local e = main.transform.eulerAngles
        pos, pitch, yaw = main.transform.position, e.x, e.y
        if pitch > 180 then pitch = pitch - 360 end
    end
    controlled, disabledComps, controlledNames, disabledNames = {}, {}, {}, {}
    resumeEngines()
    enabled = true
    scanCameras()
    detachHooks()
    attachHooks()
end

local function disable()
    enabled = false
    for _, c in ipairs(disabledComps) do
        if c then pcall(function() c.enabled = true end) end
    end
    disabledComps, controlled = {}, {}
    resumeEngines()
    detachHooks()
end

local function status()
    local hn = {}
    for _, h in ipairs(hooks) do table.insert(hn, h.name) end
    local lines = {
        "FREECAM " .. (enabled and "ON" or "OFF") .. (enabled and hard and " (HARD)" or ""),
        "Hooks: " .. (#hn > 0 and table.concat(hn, ", ") or "NONE (fallback only)"),
        "Controlling: " .. (#controlledNames > 0 and table.concat(controlledNames, ", ") or "nothing"),
        "Disabled: " .. (#disabledNames > 0 and table.concat(disabledNames, ", ") or "nothing"),
    }
    table.insert(lines, "slow motion: " .. SPEEDS[speedIdx] .. "x"
        .. (speedIdx ~= 1 and (" (game was at " .. savedScale .. "x)") or ""))
    local ec = 0
    for _, c in pairs(engines) do
        local ok, v = pcall(function() return c.PauseLateUpdateCount end)
        table.insert(lines, "PipelineCameraEngine pause count: " .. (ok and tostring(v) or "?"))
        ec = ec + 1
    end
    if ec == 0 then table.insert(lines, "PipelineCameraEngine: not found on controlled cameras") end
    for _, cam in pairs(controlled) do
        local ok, d = pcall(function() return (cam.transform.position - pos).magnitude end)
        if ok then table.insert(lines, string.format("%s offset from freecam pos: %.2f", cam.name, d)) end
    end
    popup(table.concat(lines, "\n"))
end

local function dump()
    local lines = {}
    local cams = U.Camera.allCameras
    for i = 0, cams.Length - 1 do
        local cam = cams[i]
        table.insert(lines, string.format("[%s] en=%s depth=%s rt=%s",
            cam.name, tostring(cam.enabled), tostring(cam.depth), tostring(cam.targetTexture ~= nil)))
        local ok, comps = pcall(function()
            return cam.gameObject:GetComponents(typeof(U.Component))
        end)
        if ok and comps then
            local names = {}
            for j = 0, comps.Length - 1 do
                table.insert(names, comps[j]:GetType().Name)
            end
            table.insert(lines, "  " .. table.concat(names, ", "))
        end
    end
    local text = "CAMERAS (" .. cams.Length .. ")\n" .. table.concat(lines, "\n")
    if #text > 1500 then text = text:sub(1, 1500) .. "\n..." end
    popup(text)
end

-- main loop
local function loop()
    local timer = 0
    while true do
        if _G.__FC_GEN ~= MY_GEN then
            if enabled then disable() end
            resetSlowmo()
            return
        end

        local normal, hardKey = keyDown(NORMAL_KEYS), keyDown(HARD_KEYS)
        if normal or hardKey then
            if enabled then disable() else enable(hardKey) end
        end
        if keyDown({ "F8" }) then status() end
        if keyDown({ "F9" }) then dump() end
        if keyDown({ "F6" }) then cycleSlowmo() end
        applySlowmo()

        if enabled then
            local dt = U.Time.unscaledDeltaTime

            timer = timer + dt
            if timer >= 0.5 then
                timer = 0
                scanCameras()
            end

            if U.Input.GetMouseButton(1) then
                yaw = yaw + U.Input.GetAxis("Mouse X") * 2.5
                pitch = pitch - U.Input.GetAxis("Mouse Y") * 2.5
            end
            local rs = 90 * dt
            if key("UpArrow") then pitch = pitch - rs end
            if key("DownArrow") then pitch = pitch + rs end
            if key("LeftArrow") then yaw = yaw - rs end
            if key("RightArrow") then yaw = yaw + rs end
            pitch = U.Mathf.Clamp(pitch, -89, 89)
            rot = U.Quaternion.Euler(pitch, yaw, 0)

            local fwd = rot * U.Vector3.forward
            local right = rot * U.Vector3.right
            local dir = U.Vector3.zero
            if key("W") then dir = dir + fwd end
            if key("S") then dir = dir - fwd end
            if key("A") then dir = dir - right end
            if key("D") then dir = dir + right end
            if key("E") or key("PageUp") then dir = dir + U.Vector3.up end
            if key("Q") or key("PageDown") then dir = dir - U.Vector3.up end

            local speed = 6
            if key("LeftShift") then speed = speed * 3 end
            if key("LeftControl") then speed = speed * 0.25 end
            if dir.sqrMagnitude > 0 then
                pos = pos + dir.normalized * (speed * dt)
            end

            -- always also write here: covers the case where no late hook attached
            applyAll()
        end

        coroutine.yield(nil)
    end
end

local started, err = pcall(function()
    CS.RPG.Client.CoroutineUtils.StartCoroutine(util.cs_generator(loop))
end)

if LOAD_POPUP or not started then
    popup("Freecam script loaded (copy " .. MY_GEN .. ")\n"
        .. "Coroutine started: " .. tostring(started) .. (started and "" or ("\n" .. tostring(err))))
end