-- dump.lua : run with /lua dump.lua (in battle is best)
-- Writes a text file with (1) live camera-related components, (2) camera-related game classes.
-- A short popup tells you where the file is. Send me the file.

local U = CS.UnityEngine
local lines = {}
local function add(s) lines[#lines + 1] = s end

-- 1) live components in the scene whose type name contains "Camera"
add("== LIVE COMPONENTS (type name contains 'Camera') ==")
local ok, all = pcall(function() return U.Object.FindObjectsOfType(typeof(U.MonoBehaviour)) end)
if ok and all then
    for i = 0, all.Length - 1 do
        local c = all[i]
        local okn, tn = pcall(function() return c:GetType().FullName end)
        if okn and tn and tn:find("Camera", 1, true) then
            local info = ""
            pcall(function() info = c.gameObject.name .. "  enabled=" .. tostring(c.enabled) end)
            add(tn .. "  on  " .. info)
        end
    end
else
    add("(FindObjectsOfType failed)")
end

-- 2) classes whose name contains "Camera": fields + methods declared on the class
add("")
add("== CLASSES (name contains 'Camera') ==")
local BF = CS.System.Reflection.BindingFlags
local okf, F = pcall(function() return BF.__CastFrom(62) end) -- Instance|Static|Public|NonPublic|DeclaredOnly

local skip = { "System", "mscorlib", "UnityEngine", "netstandard", "Mono", "Unity.", "nunit", "Newtonsoft" }
local function skipAsm(n)
    for _, p in ipairs(skip) do if n:sub(1, #p) == p then return true end end
    return false
end

local asms = CS.System.AppDomain.CurrentDomain:GetAssemblies()
local total = 0
for a = 0, asms.Length - 1 do
    local asm = asms[a]
    local okname, aname = pcall(function() return asm:GetName().Name end)
    if okname and aname and not skipAsm(aname) then
        local okt, types = pcall(function() return asm:GetTypes() end)
        if okt and types then
            for i = 0, types.Length - 1 do
                local t = types[i]
                local fn
                pcall(function() fn = t.FullName end)
                if fn and fn:find("Camera", 1, true) and total < 4000 then
                    local base = ""
                    pcall(function() base = t.BaseType and t.BaseType.Name or "" end)
                    add("")
                    add("[" .. aname .. "] " .. fn .. " : " .. base)
                    if okf then
                        pcall(function()
                            local fs = t:GetFields(F)
                            for j = 0, math.min(fs.Length, 60) - 1 do
                                add("    field  " .. fs[j].Name .. " : " .. fs[j].FieldType.Name)
                            end
                        end)
                        pcall(function()
                            local ms = t:GetMethods(F)
                            for j = 0, math.min(ms.Length, 60) - 1 do
                                local n = ms[j].Name
                                if n:sub(1, 4) ~= "get_" and n:sub(1, 4) ~= "set_" then
                                    add("    method " .. n)
                                end
                            end
                        end)
                    end
                    total = total + 1
                end
            end
        end
    end
end
add("")
add("classes listed: " .. total)

local path = U.Application.persistentDataPath .. "/camdump.txt"
local wrote, err = pcall(function()
    CS.System.IO.File.WriteAllText(path, table.concat(lines, "\n"))
end)

pcall(function()
    CS.RPG.Client.ConfirmDialogUtil.ShowCustomOkCancelHint(
        "DUMP " .. (wrote and "written" or ("FAILED: " .. tostring(err))) .. "\nclasses: " .. total
        .. "\n" .. path, nil)
end)