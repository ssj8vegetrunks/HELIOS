local security = {}

-- CC:Tweaked has no portable cryptographic API. This keyed 128-bit integrity
-- tag isolates ordinary multiplayer networks and rejects casual cross-control.
-- Server-side computer/peripheral permissions remain the hard security boundary.

local function validKey(value)
    return type(value) == "string" and #value >= 8 and #value <= 128
end

local function canonical(value, seen)
    local kind = type(value)
    if kind == "nil" then return "n" end
    if kind == "boolean" then return value and "b1" or "b0" end
    -- Rednet serializes Lua numbers using their ordinary string form. Using
    -- higher precision here can sign digits which do not survive transport.
    if kind == "number" then return "d" .. tostring(value) end
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind ~= "table" then return nil, "unsupported value" end
    seen = seen or {}
    if seen[value] then return nil, "cyclic value" end
    seen[value] = true
    local entries = {}
    for key, item in pairs(value) do
        if key ~= "networkAuth" then
            local encodedKey, keyError = canonical(key, seen)
            if not encodedKey then seen[value] = nil return nil, keyError end
            local encodedItem, itemError = canonical(item, seen)
            if not encodedItem then seen[value] = nil return nil, itemError end
            entries[#entries + 1] = encodedKey .. "=" .. encodedItem
        end
    end
    table.sort(entries)
    seen[value] = nil
    return "t" .. #entries .. ":{" .. table.concat(entries, ";") .. "}"
end

local function mix(text, seed)
    local hash = seed
    for index = 1, #text do
        hash = bit32.bxor(hash, string.byte(text, index))
        hash = bit32.band(hash + bit32.lshift(hash, 1) + bit32.lshift(hash, 4) +
            bit32.lshift(hash, 7) + bit32.lshift(hash, 8) + bit32.lshift(hash, 24), 0xffffffff)
        hash = bit32.bxor(hash, bit32.rrotate(hash, (index % 23) + 1))
    end
    hash = bit32.bxor(hash, bit32.rshift(hash, 16))
    hash = bit32.bxor(hash, bit32.lshift(hash, 13))
    hash = bit32.bxor(hash, bit32.rshift(hash, 17))
    return bit32.bxor(hash, bit32.lshift(hash, 5))
end

local function digest(key, text)
    local values = {
        mix(key .. "\0" .. text .. "\1" .. key, 0x811c9dc5),
        mix(key .. "\2" .. text .. "\3" .. key, 0x9e3779b9),
        mix(text .. "\4" .. key .. "\5" .. text, 0x85ebca6b),
        mix(key .. "\6" .. text .. "\7" .. string.reverse(key), 0xc2b2ae35),
    }
    return string.format("%08x%08x%08x%08x", values[1], values[2], values[3], values[4])
end

function security.enabled(config)
    local network = type(config) == "table" and config.network or nil
    return type(network) == "table" and network.securityEnabled == true and validKey(network.securityKey)
end

function security.networkId(config)
    if not security.enabled(config) then return "OPEN" end
    return string.sub(digest(config.network.securityKey, "HELIOS NETWORK ID"), 1, 12):upper()
end

function security.sign(message, config, protocol)
    if not security.enabled(config) then return message end
    if type(message) ~= "table" then return nil, "message must be a table" end
    message.networkId = security.networkId(config)
    message.networkProtocol = tostring(protocol or "")
    -- An integer millisecond timestamp survives Rednet's serialization exactly.
    message.networkSentAt = math.floor(os.epoch("utc"))
    message.networkNonce = table.concat({ tostring(os.getComputerID()), tostring(message.networkSentAt),
        tostring(math.random(1, 2147483647)) }, ":")
    local encoded, reason = canonical(message)
    if not encoded then return nil, reason end
    message.networkAuth = digest(config.network.securityKey, encoded)
    return message
end

function security.verify(message, config, protocol, now)
    if not security.enabled(config) then return true end
    if type(message) ~= "table" or type(message.networkAuth) ~= "string" or
       message.networkId ~= security.networkId(config) or message.networkProtocol ~= tostring(protocol or "") then
        return false, "network identity mismatch"
    end
    local sentAt = tonumber(message.networkSentAt)
    now = tonumber(now) or os.epoch("utc") / 1000
    if not sentAt then return false, "network message expired" end
    local sentSeconds = sentAt >= 100000000000 and sentAt / 1000 or sentAt
    local nowSeconds = now >= 100000000000 and now / 1000 or now
    local age = math.abs(nowSeconds - sentSeconds)
    if age > 30 then return false, "network message expired" end
    local encoded, reason = canonical(message)
    if not encoded then return false, reason end
    if digest(config.network.securityKey, encoded) ~= message.networkAuth then
        return false, "network authentication failed"
    end
    return true
end

function security.generateKey()
    local seed = table.concat({ tostring(os.getComputerID()), tostring(os.epoch("utc")),
        tostring(os.clock()), tostring(math.random(1, 2147483647)) }, ":")
    local raw = digest(seed, "HELIOS GENERATED NETWORK KEY")
    return "HLS-" .. string.sub(raw, 1, 6):upper() .. "-" .. string.sub(raw, 7, 12):upper()
end

function security.validKey(value) return validKey(value) end

return security
