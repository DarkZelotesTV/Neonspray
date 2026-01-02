#version 2
-- Neon Spray — Spraycan SHIM override (Fixed RMB Toggle & Added CTA)
-- * Slot 6, heißt "Spraycan", Vanilla spraycan wird deaktiviert
-- * UI: Rechtsklick (rmb) togglet, NUR wenn Tool ausgewählt
-- * Farbwahl: HSV-Palette wie Paint (Hue-Bar + S/V Feld) + Hex Anzeige
-- * MP: Server malt & verwaltet permanente Lichter

local MOD_TOOL_ID = "neonspray"
local VANILLA_TOOL_ID = "spraycan"

-- ---------- Defaults ----------
local DEFAULT = {
    range = 25.0,
    radius = 0.35,
    probability = 0.25,
    alpha = 1.0,

    dotLifetime = 6.0,
    dotSize = 0.06,
    dotEmissive = 5.0,
    dotSticky = 1.0,

    lightsEnabled = true,
    lightIntensity = 0.7,
    maxLights = 350,
    lightGrid = 0.25,

    -- Color picker defaults (HSV)
    hue = 320/360,    -- 0..1
    sat = 0.85,       -- 0..1
    val = 1.0         -- 0..1
}

-- Savegame keys
local SGK = {
    hex = "savegame.mod.neonspray_hex",
    radius = "savegame.mod.neonspray_radius",
    prob = "savegame.mod.neonspray_prob",
    glow = "savegame.mod.neonspray_glow",
    glowSize = "savegame.mod.neonspray_glowsize",
    lights = "savegame.mod.neonspray_lights",
    intensity = "savegame.mod.neonspray_intensity",
    maxLights = "savegame.mod.neonspray_maxlights",
    grid = "savegame.mod.neonspray_grid",

    hue = "savegame.mod.neonspray_hue",
    sat = "savegame.mod.neonspray_sat",
    val = "savegame.mod.neonspray_val",

    defaultSet = "savegame.mod.neonspray_defaultset"
}

client = client or {}
client.textInput = client.textInput or { active = nil, buffer = "" }

-- ---------- Utils ----------
local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function nibbleToHex(n)
    return string.format("%X", clamp(n, 0, 15))
end

local function digitsToHexString(d)
    return "#" ..
        nibbleToHex(d[1]) .. nibbleToHex(d[2]) ..
        nibbleToHex(d[3]) .. nibbleToHex(d[4]) ..
        nibbleToHex(d[5]) .. nibbleToHex(d[6])
end

local function hexToRgb01(hex)
    hex = hex:gsub("#", "")
    if #hex ~= 6 then return 1, 0, 1 end
    local r = tonumber(hex:sub(1,2), 16) or 255
    local g = tonumber(hex:sub(3,4), 16) or 0
    local b = tonumber(hex:sub(5,6), 16) or 255
    return r/255, g/255, b/255
end

local function rgb01ToHexDigits(r, g, b)
    local rr = clamp(math.floor(r*255 + 0.5), 0, 255)
    local gg = clamp(math.floor(g*255 + 0.5), 0, 255)
    local bb = clamp(math.floor(b*255 + 0.5), 0, 255)
    local hex = string.format("%02X%02X%02X", rr, gg, bb)
    local d = {}
    for i=1,6 do
        d[i] = tonumber(hex:sub(i,i), 16) or 0
    end
    return d
end

local function digitsToPacked(d)
    return nibbleToHex(d[1]) .. nibbleToHex(d[2]) .. nibbleToHex(d[3]) .. nibbleToHex(d[4]) .. nibbleToHex(d[5]) .. nibbleToHex(d[6])
end

local function packedToDigits(s)
    s = (s or ""):gsub("#",""):upper()
    if #s ~= 6 then return nil end
    local d = {}
    for i=1,6 do
        local v = tonumber(s:sub(i,i), 16)
        if v == nil then return nil end
        d[i] = v
    end
    return d
end

-- HSV (0..1) -> RGB (0..1)
local function hsvToRgb(h, s, v)
    h = (h or 0) % 1.0
    s = clamp(s or 0, 0, 1)
    v = clamp(v or 0, 0, 1)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p end
    if i == 1 then return q, v, p end
    if i == 2 then return p, v, t end
    if i == 3 then return p, q, v end
    if i == 4 then return t, p, v end
    return v, p, q
end

local function snapToGrid(p, grid)
    local g = grid or DEFAULT.lightGrid
    return Vec(
        math.floor(p[1]/g + 0.5)*g,
        math.floor(p[2]/g + 0.5)*g,
        math.floor(p[3]/g + 0.5)*g
    )
end

local function keyForPos(p)
    return string.format("%d_%d_%d", math.floor(p[1]*1000+0.5), math.floor(p[2]*1000+0.5), math.floor(p[3]*1000+0.5))
end

-- =========================================================
-- ========================== SERVER =======================
-- =========================================================
server.players = server.players or {}
server.lastSpray = server.lastSpray or {}
server.lightMap = server.lightMap or {}
server.lightList = server.lightList or {}

function server.init()
    RegisterTool(MOD_TOOL_ID, "Spraycan", "MOD/vox/neonspray_spraycan.vox", 6)
    SetBool("game.tool." .. MOD_TOOL_ID .. ".enabled", true)
    SetBool("game.tool." .. VANILLA_TOOL_ID .. ".enabled", false)
end

local function getPlayerSettings(playerId)
    local s = server.players[playerId]
    if not s then
        s = {
            cfg = {
                radius = DEFAULT.radius,
                probability = DEFAULT.probability,
                alpha = DEFAULT.alpha,
                dotEmissive = DEFAULT.dotEmissive,
                dotSize = DEFAULT.dotSize,
                lightsEnabled = DEFAULT.lightsEnabled,
                lightIntensity = DEFAULT.lightIntensity,
                maxLights = DEFAULT.maxLights,
                lightGrid = DEFAULT.lightGrid
            },
            hexDigits = {15, 0, 0, 15, 0, 15}
        }
        server.players[playerId] = s
    end
    return s
end

function server.setPlayerSettings(playerId, hexDigits, radius, probability, dotEmissive, dotSize, lightsEnabled, intensity, maxLights, grid)
    local s = getPlayerSettings(playerId)

    if type(hexDigits) == "table" and #hexDigits == 6 then
        for i=1,6 do
            local v = tonumber(hexDigits[i]) or 0
            s.hexDigits[i] = v % 16
        end
    end

    if radius ~= nil then s.cfg.radius = clamp(radius, 0.05, 2.0) end
    if probability ~= nil then s.cfg.probability = clamp(probability, 0.0, 1.0) end
    if dotEmissive ~= nil then s.cfg.dotEmissive = clamp(dotEmissive, 0.0, 25.0) end
    if dotSize ~= nil then s.cfg.dotSize = clamp(dotSize, 0.01, 0.25) end
    if lightsEnabled ~= nil then s.cfg.lightsEnabled = not not lightsEnabled end
    if intensity ~= nil then s.cfg.lightIntensity = clamp(intensity, 0.0, 1.25) end
    if maxLights ~= nil then s.cfg.maxLights = math.floor(clamp(maxLights, 0, 2000)) end
    if grid ~= nil then s.cfg.lightGrid = clamp(grid, 0.05, 1.0) end
end

local function serverRemoveOldestLight()
    if #server.lightList == 0 then return end
    local removed = table.remove(server.lightList, 1)
    server.lightMap[removed.key] = nil
    for i=1,#server.lightList do
        server.lightMap[server.lightList[i].key] = i
    end
    ClientCall(0, "client.removeLight", removed.key)
end

local function serverAddOrUpdateLight(pos, r, g, b, maxLights, grid)
    local p = snapToGrid(pos, grid)
    local key = keyForPos(p)

    local idx = server.lightMap[key]
    if idx then
        local L = server.lightList[idx]
        L.pos, L.r, L.g, L.b = p, r, g, b
        ClientCall(0, "client.addOrUpdateLight", key, p, r, g, b)
        return
    end

    while #server.lightList >= maxLights do
        serverRemoveOldestLight()
    end

    server.lightList[#server.lightList+1] = { key=key, pos=p, r=r, g=g, b=b }
    server.lightMap[key] = #server.lightList
    ClientCall(0, "client.addOrUpdateLight", key, p, r, g, b)
end

function server.clearAllLights()
    server.lightMap = {}
    server.lightList = {}
    ClientCall(0, "client.clearAllLights")
end

function server.spray(playerId, camPos, camDir)
    local t = GetTime()
    local last = server.lastSpray[playerId] or -1
    if t - last < 0.05 then return end
    server.lastSpray[playerId] = t

    local s = getPlayerSettings(playerId)
    QueryRequire("physical")
    local hit, dist = QueryRaycast(camPos, camDir, DEFAULT.range)
    if not hit then return end

    local hitPos = VecAdd(camPos, VecScale(camDir, dist))
    local hex = digitsToHexString(s.hexDigits)
    local r, g, b = hexToRgb01(hex)

    PaintRGBA(hitPos, s.cfg.radius, r, g, b, s.cfg.alpha, s.cfg.probability)
    ClientCall(0, "client.spawnSprayFx", hitPos, r, g, b, s.cfg.dotEmissive, s.cfg.dotSize)

    if s.cfg.lightsEnabled and s.cfg.lightIntensity > 0 then
        serverAddOrUpdateLight(hitPos, r, g, b, s.cfg.maxLights, s.cfg.lightGrid)
    end
end

function server.syncLightsToClient(playerId)
    for i=1,#server.lightList do
        local L = server.lightList[i]
        ClientCall(playerId, "client.addOrUpdateLight", L.key, L.pos, L.r, L.g, L.b)
    end
end

-- =========================================================
-- ========================== CLIENT =======================
-- =========================================================
client.uiOpen = client.uiOpen or false
client.hexDigits = client.hexDigits or {15, 0, 0, 15, 0, 15}
client.cfg = client.cfg or {
    radius = DEFAULT.radius,
    probability = DEFAULT.probability,
    dotEmissive = DEFAULT.dotEmissive,
    dotSize = DEFAULT.dotSize,
    lightsEnabled = DEFAULT.lightsEnabled,
    lightIntensity = DEFAULT.lightIntensity,
    maxLights = DEFAULT.maxLights,
    lightGrid = DEFAULT.lightGrid
}
client.picker = client.picker or {
    hue = DEFAULT.hue,
    sat = DEFAULT.sat,
    val = DEFAULT.val
}

client._dirty = true
client._lastSent = -1

client.lightMap = client.lightMap or {}
client.lightList = client.lightList or {}

local function isModSpraycanSelected()
    return GetString("game.player.tool") == MOD_TOOL_ID
end

local function isVanillaSpraycanSelected()
    return GetString("game.player.tool") == VANILLA_TOOL_ID
end

local function forceModToolIfVanillaSelected()
    if isVanillaSpraycanSelected() then
        SetString("game.player.tool", MOD_TOOL_ID)
    end
end

local function spawnGlowDot(pos, r, g, b, emissive, size)
    ParticleReset()
    ParticleType("plain")
    ParticleRadius(size)
    ParticleColor(r, g, b)
    ParticleEmissive(emissive, emissive)
    ParticleSticky(DEFAULT.dotSticky)
    ParticleCollide(0)
    ParticleGravity(0)
    SpawnParticle(pos, Vec(0,0,0), DEFAULT.dotLifetime)
end

local function saveSettings()
    SetString(SGK.hex, digitsToPacked(client.hexDigits))
    SetFloat(SGK.radius, client.cfg.radius)
    SetFloat(SGK.prob, client.cfg.probability)
    SetFloat(SGK.glow, client.cfg.dotEmissive)
    SetFloat(SGK.glowSize, client.cfg.dotSize)
    SetBool(SGK.lights, client.cfg.lightsEnabled)
    SetFloat(SGK.intensity, client.cfg.lightIntensity)
    SetFloat(SGK.maxLights, client.cfg.maxLights)
    SetFloat(SGK.grid, client.cfg.lightGrid)

    SetFloat(SGK.hue, client.picker.hue)
    SetFloat(SGK.sat, client.picker.sat)
    SetFloat(SGK.val, client.picker.val)
end

local function loadSettings()
    local d = packedToDigits(GetString(SGK.hex))
    if d then client.hexDigits = d end

    client.cfg.radius = clamp(GetFloat(SGK.radius, DEFAULT.radius), 0.05, 2.0)
    client.cfg.probability = clamp(GetFloat(SGK.prob, DEFAULT.probability), 0.0, 1.0)
    client.cfg.dotEmissive = clamp(GetFloat(SGK.glow, DEFAULT.dotEmissive), 0.0, 25.0)
    client.cfg.dotSize = clamp(GetFloat(SGK.glowSize, DEFAULT.dotSize), 0.01, 0.25)
    client.cfg.lightsEnabled = GetBool(SGK.lights, DEFAULT.lightsEnabled)
    client.cfg.lightIntensity = clamp(GetFloat(SGK.intensity, DEFAULT.lightIntensity), 0.0, 1.25)
    client.cfg.maxLights = math.floor(clamp(GetFloat(SGK.maxLights, DEFAULT.maxLights), 0, 2000))
    client.cfg.lightGrid = clamp(GetFloat(SGK.grid, DEFAULT.lightGrid), 0.05, 1.0)

    client.picker.hue = clamp(GetFloat(SGK.hue, DEFAULT.hue), 0.0, 1.0)
    client.picker.sat = clamp(GetFloat(SGK.sat, DEFAULT.sat), 0.0, 1.0)
    client.picker.val = clamp(GetFloat(SGK.val, DEFAULT.val), 0.0, 1.0)
end

local function sendSettingsToServer(force)
    local t = GetTime()
    if (not force) and (t - (client._lastSent or -1) < 0.10) then return end
    client._lastSent = t
    client._dirty = false
    ServerCall("server.setPlayerSettings",
        GetLocalPlayer(),
        client.hexDigits,
        client.cfg.radius,
        client.cfg.probability,
        client.cfg.dotEmissive,
        client.cfg.dotSize,
        client.cfg.lightsEnabled,
        client.cfg.lightIntensity,
        client.cfg.maxLights,
        client.cfg.lightGrid
    )
end

function client.addOrUpdateLight(key, pos, r, g, b)
    local idx = client.lightMap[key]
    if idx then
        local L = client.lightList[idx]
        L.pos, L.r, L.g, L.b = pos, r, g, b
        return
    end
    client.lightList[#client.lightList+1] = {key=key, pos=pos, r=r, g=g, b=b}
    client.lightMap[key] = #client.lightList
end

function client.removeLight(key)
    local idx = client.lightMap[key]
    if not idx then return end
    table.remove(client.lightList, idx)
    client.lightMap[key] = nil
    for i=1,#client.lightList do
        client.lightMap[client.lightList[i].key] = i
    end
end

function client.clearAllLights()
    client.lightList = {}
    client.lightMap = {}
end

local function renderPermanentLights()
    if not client.cfg.lightsEnabled or client.cfg.lightIntensity <= 0 then return end
    local intensity = client.cfg.lightIntensity
    for i=1,#client.lightList do
        local L = client.lightList[i]
        PointLight(L.pos, L.r, L.g, L.b, intensity)
    end
end

function client.init()
    loadSettings()
    client._dirty = true

    if not GetBool(SGK.defaultSet, false) then
        SetBool(SGK.defaultSet, true)
        SetString("game.player.tool", MOD_TOOL_ID)
    end

    SetBool("game.tool." .. VANILLA_TOOL_ID .. ".enabled", false)
    ServerCall("server.syncLightsToClient", GetLocalPlayer())
end

function client.spawnSprayFx(hitPos, r, g, b, dotEmissive, dotSize)
    spawnGlowDot(hitPos, r, g, b, dotEmissive, dotSize)
end

function client.tick(dt)
    renderPermanentLights()
    forceModToolIfVanillaSelected()

    --- UI & INPUT LOGIC ---
    
    -- Handle Right Click (RMB)
    if isModSpraycanSelected() then
        if InputPressed("rmb") then
            -- Prio 1: Shift+RMB (Löschen)
            if InputDown("shift") then
                ServerCall("server.clearAllLights")
                InputClear("rmb")
            -- Prio 2: UI Toggle (Nur wenn nicht getippt wird)
            elseif not client.textInput.active then
                client.uiOpen = not client.uiOpen
                
                -- Immer InputClear um sauberes Toggle zu garantieren
                InputClear("rmb")
                
                if not client.uiOpen then
                    -- Wenn geschlossen wird: Reset Input
                    client.textInput.active = nil
                    client.textInput.buffer = ""
                end
            end
        end
    else
        -- Wenn Tool nicht gewählt ist, UI schließen
        client.uiOpen = false
        client.textInput.active = nil
        client.textInput.buffer = ""
    end

    -- Handle UI State
    if client.uiOpen then
        UiMakeInteractive()

        local typingCommitted = false
        if uiHandleTyping() then
            typingCommitted = true
            uiCommitActiveField()
        end

        if InputPressed("esc") or InputPressed("escape") then
            client.uiOpen = false
            client.textInput.active = nil
            client.textInput.buffer = ""
            InputClear("esc")
            InputClear("escape")
        end

        if client._dirty then
            sendSettingsToServer(false)
        end
        
        -- Wenn UI offen ist, return (Rest wird nicht ausgeführt)
        -- Keine Tool-Logik nötig, da das Tool im Standard-Modus ist
        return 
    end

    --- SPRAY LOGIC ---
    
    -- Keine SetToolTransform Aufrufe!
    -- Das Tool wird durch das Spiel in der Standard-Animation gehalten.

    if InputDown("usetool") and isModSpraycanSelected() then
        local cam = GetPlayerCameraTransform()
        local dir = TransformToParentVec(cam, Vec(0,0,-1))
        ServerCall("server.spray", GetLocalPlayer(), cam.pos, dir)
    end

    if client._dirty then sendSettingsToServer(false) end
end

-- =========================================================
-- =========================== UI ==========================
-- =========================================================

local function uiText(a, s)
    UiFont("regular.ttf", a)
    UiText(s)
end

local function uiLabel(s)
    UiFont("regular.ttf", 18)
    UiColor(1,1,1,0.85)
    UiText(s)
    UiColor(1,1,1,1)
end

local function uiSection(s)
    UiFont("regular.ttf", 20)
    UiColor(1,1,1,0.95)
    UiText(s)
    UiColor(1,1,1,1)
    UiTranslate(0, 8) 
end

local function uiSwatch(w, h, r, g, b, selected)
    local inside = UiIsMouseInRect(w, h)
    UiPush()
        UiColor(r, g, b, 1)
        UiRect(w, h)

        if selected then
            UiColor(1,1,1,0.85)
            UiTranslate(2,2)
            UiRect(w-4, h-4)
        elseif inside then
            UiColor(1,1,1,0.25)
            UiTranslate(2,2)
            UiRect(w-4, h-4)
        end
    UiPop()

    local clicked = inside and InputPressed("lmb") and UiReceivesInput()
    return clicked
end

local function uiNumBox(id, label, value, minv, maxv, step, fmt, isInt)
    step = step or 0.1
    fmt = fmt or (isInt and "%d" or "%.2f")

    local boxW, boxH = 200, 32  

    UiFont("regular.ttf", 18)
    UiColor(1,1,1,0.85)
    UiText(label .. " " .. string.format(fmt, value))
    UiColor(1,1,1,1)
    UiTranslate(0, 18) 

    UiPush()
        local inside = UiIsMouseInRect(boxW, boxH)

        if client.textInput.active == id then
            UiColor(0.15,0.15,0.15,0.85)
        else
            UiColor(0,0,0,0.35)
        end
        UiRoundedRect(boxW, boxH, 6)

        UiTranslate(10, 8)
        UiFont("regular.ttf", 18)
        UiColor(1,1,1,0.95)
        local shown = (client.textInput.active == id) and client.textInput.buffer or string.format(fmt, value)
        UiText(shown)
        UiColor(1,1,1,1)

        if inside and InputPressed("lmb") and UiReceivesInput() then
            client.textInput.active = id
            client.textInput.buffer = isInt and tostring(math.floor(value)) or tostring(value)
            InputClear("lmb")
        end
    UiPop()

    -- +/- Buttons
    UiPush()
        UiTranslate(boxW + 10, 0) 
        UiFont("regular.ttf", 18)
        if UiTextButton("−") then
            value = value - step
        end
        UiTranslate(40, 0)
        if UiTextButton("+") then
            value = value + step
        end
    UiPop()

    value = clamp(value, minv, maxv)
    if isInt then value = math.floor(value + 0.5) end

    UiTranslate(0, 52) 
    return value
end

function uiHandleTyping()
    if not client.textInput.active then return false end

    for d=0,9 do
        local k = tostring(d)
        if InputPressed(k) then
            client.textInput.buffer = client.textInput.buffer .. k
            InputClear(k)
        end
    end

    if InputPressed(".") or InputPressed("period") then
        if not string.find(client.textInput.buffer, ".", 1, true) then
            client.textInput.buffer = client.textInput.buffer .. "."
        end
        InputClear(".")
        InputClear("period")
    end
    if InputPressed(",") or InputPressed("comma") then
        if not string.find(client.textInput.buffer, ".", 1, true) then
            client.textInput.buffer = client.textInput.buffer .. "."
        end
        InputClear(",")
        InputClear("comma")
    end

    if InputPressed("-") or InputPressed("minus") then
        if #client.textInput.buffer == 0 then
            client.textInput.buffer = "-"
        end
        InputClear("-")
        InputClear("minus")
    end

    if InputPressed("backspace") or InputPressed("bs") then
        client.textInput.buffer = client.textInput.buffer:sub(1, math.max(0, #client.textInput.buffer - 1))
        InputClear("backspace")
        InputClear("bs")
    end

    if InputPressed("enter") or InputPressed("return") then
        InputClear("enter")
        InputClear("return")
        return true
    end

    if InputPressed("esc") then
        InputClear("esc")
        client.textInput.active = nil
        return false 
    end

    return false
end

function uiCommitActiveField()
    local id = client.textInput.active
    if not id then return end

    local raw = (client.textInput.buffer or ""):gsub(",", ".")
    local num = tonumber(raw)
    
    if not num then
        client.textInput.active = nil
        client.textInput.buffer = ""
        return 
    end

    if id == "radius" then
        num = clamp(num, 0.05, 2.0)
        if math.abs(num - client.cfg.radius) > 0.0001 then client.cfg.radius = num; client._dirty = true; saveSettings() end
    elseif id == "prob" then
        num = clamp(num, 0.0, 1.0)
        if math.abs(num - client.cfg.probability) > 0.0001 then client.cfg.probability = num; client._dirty = true; saveSettings() end
    elseif id == "glow" then
        num = clamp(num, 0.0, 25.0)
        if math.abs(num - client.cfg.dotEmissive) > 0.0001 then client.cfg.dotEmissive = num; client._dirty = true; saveSettings() end
    elseif id == "glowSize" then
        num = clamp(num, 0.01, 0.25)
        if math.abs(num - client.cfg.dotSize) > 0.0001 then client.cfg.dotSize = num; client._dirty = true; saveSettings() end
    elseif id == "intensity" then
        num = clamp(num, 0.0, 1.25)
        if math.abs(num - client.cfg.lightIntensity) > 0.0001 then client.cfg.lightIntensity = num; client._dirty = true; saveSettings() end
    elseif id == "maxLights" then
        num = math.floor(clamp(num, 0, 2000) + 0.5)
        if num ~= client.cfg.maxLights then client.cfg.maxLights = num; client._dirty = true; saveSettings() end
    elseif id == "grid" then
        num = clamp(num, 0.05, 1.0)
        if math.abs(num - client.cfg.lightGrid) > 0.0001 then client.cfg.lightGrid = num; client._dirty = true; saveSettings() end
    end

    client.textInput.buffer = ""
    client.textInput.active = nil
end

local function uiColorPicker()
    local changed = false
    local cr, cg, cb = hsvToRgb(client.picker.hue, client.picker.sat, client.picker.val)
    local hex = digitsToHexString(client.hexDigits)

    uiSection("Color")
    UiTranslate(0, 10)

    UiPush()
        UiColor(cr, cg, cb, 1)
        UiRoundedRect(260, 18, 6)
    UiPop()
    UiTranslate(0, 26)

    UiFont("regular.ttf", 18)
    UiText("Current: " .. hex)
    UiTranslate(0, 14)
    UiFont("regular.ttf", 16)
    UiColor(1,1,1,0.70)
    UiText("LMB: pick color • Enter: apply • ESC: cancel")
    UiColor(1,1,1,1)
    UiTranslate(0, 20)

    -- Hue bar
    uiLabel("Hue")
    UiTranslate(0, 12)
    local barW, barH = 360, 18
    local steps = 24
    local sw = barW/steps

    UiPush()
        for i=0,steps-1 do
            UiPush()
                UiTranslate(i*sw, 0)
                local h = i/(steps)
                local r,g,b = hsvToRgb(h, 1, 1)
                local sel = math.abs(h - client.picker.hue) < (1/steps)
                if uiSwatch(sw-1, barH, r,g,b, sel) then
                    client.picker.hue = h
                    changed = true
                end
            UiPop()
        end
    UiPop()
    UiTranslate(0, 44)

    -- S/V field
    uiLabel("Saturation / Brightness")
    UiTranslate(0, 12)
    local gridCols, gridRows = 12, 10
    local cell = 26
    local fieldH = gridCols*cell

    UiPush()
        for y=0,gridRows-1 do
            for x=0,gridCols-1 do
                UiPush()
                    UiTranslate(x*cell, y*cell)
                    local s = x/(gridCols-1)
                    local v = 1 - (y/(gridRows-1))
                    local r,g,b = hsvToRgb(client.picker.hue, s, v)
                    local sel = (math.abs(s - client.picker.sat) < 0.06) and (math.abs(v - client.picker.val) < 0.08)
                    if uiSwatch(cell-1, cell-1, r,g,b, sel) then
                        client.picker.sat = s
                        client.picker.val = v
                        changed = true
                    end
                UiPop()
            end
        end
    UiPop()
    UiTranslate(0, fieldH + 18)

    UiFont("regular.ttf", 18)
    if UiTextButton("White") then client.picker.sat = 0; client.picker.val = 1; changed = true end
    UiTranslate(90, 0)
    if UiTextButton("Black") then client.picker.sat = 0; client.picker.val = 0; changed = true end
    UiTranslate(110, 0)
    if UiTextButton("Random") then
        client.picker.hue = math.random()
        client.picker.sat = math.random()
        client.picker.val = 0.6 + math.random()*0.4
        changed = true
    end
    UiTranslate(-200, 40)

    if changed then
        local r,g,b = hsvToRgb(client.picker.hue, client.picker.sat, client.picker.val)
        client.hexDigits = rgb01ToHexDigits(r, g, b)
        client._dirty = true
        saveSettings()
    end

    return changed
end

function client.draw()
    if not client.uiOpen then
        if isModSpraycanSelected() then
            UiPush()
                UiAlign("left top")
                UiTranslate(24, 92)
                UiFont("regular.ttf", 18)
                UiColor(1,1,1,0.75)
                UiText("Neon Spray: Right-click = Settings")
            UiPop()
        end
        return
    end

    UiMakeInteractive()

    local panelW, panelH = 940, 880 
    local padX, padY = 30, 30
    local colGap = 50
    local leftW = 420

    UiPush()
        UiAlign("left top")
        UiTranslate(20, 30)

        UiColor(0,0,0,0.75)
        UiRoundedRect(panelW, panelH, 14)

        UiTranslate(padX, padY)
        UiColor(1,1,1,1)

        UiFont("regular.ttf", 28)
        UiText("Neon Spray – Settings")
        UiTranslate(0, 24)
        UiFont("regular.ttf", 16)
        UiColor(1,1,1,0.72)
        UiText("UI only with spraycan selected • Shift+Right-click: clear lights")
        UiColor(1,1,1,1)
        UiTranslate(0, 24)

        UiPush()
            uiColorPicker()
        UiPop()

        UiPush()
            UiTranslate(leftW + colGap, 0)

            uiSection("Spray")
            UiTranslate(0, 10)
            do
                local old = client.cfg.radius
                local v = uiNumBox("radius", "Radius:", old, 0.05, 2.0, 0.05, "%.2f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.radius = v; client._dirty = true; saveSettings() end
            end
            do
                local old = client.cfg.probability
                local v = uiNumBox("prob", "Density:", old, 0.0, 1.0, 0.05, "%.2f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.probability = v; client._dirty = true; saveSettings() end
            end

            uiSection("Glow (particles)")
            UiTranslate(0, 10)
            do
                local old = client.cfg.dotEmissive
                local v = uiNumBox("glow", "Intensity:", old, 0.0, 25.0, 0.5, "%.1f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.dotEmissive = v; client._dirty = true; saveSettings() end
            end
            do
                local old = client.cfg.dotSize
                local v = uiNumBox("glowSize", "Size:", old, 0.01, 0.25, 0.01, "%.2f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.dotSize = v; client._dirty = true; saveSettings() end
            end

            uiSection("Permanent lights")
            UiTranslate(0, 10)
            UiFont("regular.ttf", 18)
            if UiTextButton("Lights: " .. (client.cfg.lightsEnabled and "ON" or "OFF")) then
                client.cfg.lightsEnabled = not client.cfg.lightsEnabled
                client._dirty = true
                saveSettings()
            end
            UiTranslate(0, 40) 

            do
                local old = client.cfg.lightIntensity
                local v = uiNumBox("intensity", "Intensity (max 1.25):", old, 0.0, 1.25, 0.05, "%.2f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.lightIntensity = v; client._dirty = true; saveSettings() end
            end
            do
                local old = client.cfg.maxLights
                local v = uiNumBox("maxLights", "Max lights:", old, 0, 2000, 10, "%d", true)
                if v ~= old then client.cfg.maxLights = v; client._dirty = true; saveSettings() end
            end
            do
                local old = client.cfg.lightGrid
                local v = uiNumBox("grid", "Grid (m):", old, 0.05, 1.0, 0.05, "%.2f", false)
                if math.abs(v - old) > 0.0001 then client.cfg.lightGrid = v; client._dirty = true; saveSettings() end
            end

            UiTranslate(0, 20)
            UiFont("regular.ttf", 18)
            if UiTextButton("Clear all lights (server)") then
                ServerCall("server.clearAllLights")
            end
            UiTranslate(0, 20)
            
            UiFont("regular.ttf", 15)
            UiColor(1,1,1,0.70)
            UiWordWrap(360)
            UiText("Tip: Grid > 0.20 m, Max < 500 = significantly less FPS pain.")
            UiColor(1,1,1,1)

            -- Workshop Call To Action
            UiTranslate(0, 10)
            UiFont("regular.ttf", 16)
            UiColor(1,1,0.5,1.0) -- Goldgelb Farbe
            UiWordWrap(360)
            UiText("Enjoying the mod? Please leave a Like and a Rating on the Workshop!")
            UiColor(1,1,1,1)

        UiPop()

        if client._dirty then
            sendSettingsToServer(false)
        end
    UiPop()
end