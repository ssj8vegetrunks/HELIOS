local authority = {}

local function normalise(mode)
    if mode == "control" or mode == "monitor" then return mode end
    return "auto"
end

function authority.new(mode, localId)
    return { mode = normalise(mode), localId = tonumber(localId), peers = {} }
end

function authority.observe(state, sender, message, now)
    if type(message) ~= "table" or message.kind ~= "mainframe_presence" then return false end
    local id = tonumber(sender)
    if not id or id == state.localId then return false end
    state.peers[tostring(id)] = {
        id = id,
        mode = normalise(message.authority),
        lastSeen = tonumber(now) or 0,
    }
    local previous = state.mode
    if message.authority == "control" and
       (state.mode == "auto" or (state.mode == "control" and id < state.localId)) then
        state.mode = "monitor"
    end
    return state.mode ~= previous
end

function authority.expire(state, now, timeout)
    local changed = false
    for key, peer in pairs(state.peers) do
        if (tonumber(now) or 0) - (tonumber(peer.lastSeen) or 0) > (timeout or 5) then
            state.peers[key] = nil
            changed = true
        end
    end
    return changed
end

function authority.select(state, mode)
    state.mode = normalise(mode)
    if state.mode == "control" then
        for _, peer in pairs(state.peers) do
            if peer.mode == "control" and peer.id < state.localId then
                state.mode = "monitor"
                break
            end
        end
    end
    return state.mode
end

function authority.peerCount(state)
    local count = 0
    for _ in pairs(state.peers) do count = count + 1 end
    return count
end

function authority.controllingPeer(state)
    for _, peer in pairs(state.peers) do
        if peer.mode == "control" then return peer end
    end
end

function authority.needsSelection(state)
    return state.mode == "auto" and authority.peerCount(state) > 0
end

function authority.canControl(state)
    return state.mode == "control" or
        (state.mode == "auto" and authority.peerCount(state) == 0)
end

return authority
