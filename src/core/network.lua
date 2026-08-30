local network = {}

-- @section MODEM AND REDNET TRANSPORT
network.protocol = "helios.v1"
local PEER_FILE = "/helios/data/terminals.lua"

local function hasType(name, wanted)
    for _, peripheralType in ipairs({ peripheral.getType(name) }) do
        if peripheralType == wanted then return true end
    end
    return false
end

function network.openAll()
    local opened = 0
    for _, name in ipairs(peripheral.getNames()) do
        if hasType(name, "modem") and not rednet.isOpen(name) then
            local ok = pcall(rednet.open, name)
            if ok then opened = opened + 1 end
        elseif hasType(name, "modem") then
            opened = opened + 1
        end
    end
    return opened
end

function network.sendOn(protocol, target, message)
    if type(protocol) ~= "string" or protocol == "" or
       type(target) ~= "number" or type(message) ~= "table" then return false end
    return rednet.send(target, message, protocol)
end

function network.broadcastOn(protocol, message)
    if type(protocol) ~= "string" or protocol == "" or type(message) ~= "table" then
        return false
    end
    rednet.broadcast(message, protocol)
    return true
end

function network.send(target, message)
    return network.sendOn(network.protocol, target, message)
end

function network.broadcast(message)
    return network.broadcastOn(network.protocol, message)
end

function network.valid(message, kind)
    return type(message) == "table" and message.helios == true and
        (kind == nil or message.kind == kind)
end

function network.now()
    return os.epoch("utc") / 1000
end

-- @section SESSION IDENTITY AND PEERS
function network.sessionId(role)
    local seed = table.concat({
        tostring(role or "helios"),
        tostring(os.getComputerID()),
        tostring(os.epoch("utc")),
        tostring(os.clock()),
        tostring(math.random(1, 2147483647)),
    }, ":")
    return seed
end

function network.loadPeers()
    if not fs.exists(PEER_FILE) then return {} end
    local ok, peers = pcall(dofile, PEER_FILE)
    return ok and type(peers) == "table" and peers or {}
end

function network.savePeers(peers)
    if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
    local handle, reason = fs.open(PEER_FILE, "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize(peers))
    handle.close()
    return true
end

return network
