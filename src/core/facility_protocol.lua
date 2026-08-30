local protocol = {}

protocol.name = "helios.facility"
protocol.version = 1
protocol.rednetProtocol = "helios.facility.v1"

local kinds = {
    hello = true,
    welcome = true,
    heartbeat = true,
    telemetry = true,
    ui_offer = true,
    ui_request = true,
    acknowledgement = true,
    status = true,
    error = true,
}

local roles = {
    guardian = true,
    facility = true,
    mainframe = true,
    overseer = true,
}

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function copySafe(value, state, depth)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then return value end
    if kind == "number" then return finite(value) and value or nil end
    if kind ~= "table" then return nil end

    state = state or { seen = {}, entries = 0 }
    depth = depth or 0
    if depth >= 8 then state.invalid = "Payload nesting exceeds 8 levels" return nil end
    if state.seen[value] then state.invalid = "Payload contains a cycle" return nil end
    state.seen[value] = true

    local result = {}
    for key, item in pairs(value) do
        state.entries = state.entries + 1
        if state.entries > 512 then
            state.invalid = "Payload exceeds 512 entries"
            return nil
        end
        local keyType = type(key)
        local safeKey = (keyType == "string" or keyType == "boolean" or
            (keyType == "number" and finite(key))) and key or nil
        local safeValue = copySafe(item, state, depth + 1)
        if safeKey ~= nil and safeValue ~= nil then result[safeKey] = safeValue end
    end
    state.seen[value] = nil
    return result
end

local function sanitize(value)
    local state = { seen = {}, entries = 0 }
    local result = copySafe(value, state, 0)
    if state.invalid then return nil, state.invalid end
    return result
end

local function nonempty(value, limit)
    return type(value) == "string" and value ~= "" and #value <= (limit or 96)
end

local function validSequence(value)
    return finite(value) and value >= 0 and value % 1 == 0
end

local function validateSource(source)
    if type(source) ~= "table" then return nil, "Message source is required" end
    if not finite(source.computerId) or source.computerId < 0 or source.computerId % 1 ~= 0 then
        return nil, "Source computerId must be a non-negative integer"
    end
    if not nonempty(source.nodeId) then return nil, "Source nodeId is required" end
    if not nonempty(source.sessionId, 160) then return nil, "Source sessionId is required" end
    if not roles[source.role] then return nil, "Unsupported source role" end
    return {
        computerId = source.computerId,
        nodeId = source.nodeId,
        sessionId = source.sessionId,
        role = source.role,
        software = nonempty(source.software) and source.software or nil,
        softwareVersion = nonempty(source.softwareVersion) and source.softwareVersion or nil,
    }
end

function protocol.identity(fields)
    fields = fields or {}
    local source, reason = validateSource({
        computerId = fields.computerId == nil and os.getComputerID() or fields.computerId,
        nodeId = fields.nodeId,
        sessionId = fields.sessionId,
        role = fields.role,
        software = fields.software,
        softwareVersion = fields.softwareVersion,
    })
    if not source then return nil, reason end
    return source
end

function protocol.messageId(message)
    if type(message) ~= "table" or type(message.source) ~= "table" or
       not nonempty(message.source.sessionId, 160) or not validSequence(message.sequence) then
        return nil
    end
    return message.source.sessionId .. ":" .. tostring(message.sequence)
end

function protocol.make(kind, source, sequence, payload, sentAt)
    if not kinds[kind] then return nil, "Unsupported facility message kind" end
    local cleanSource, sourceError = validateSource(source)
    if not cleanSource then return nil, sourceError end
    if not validSequence(sequence) then return nil, "Sequence must be a non-negative integer" end
    local cleanPayload, payloadError = sanitize(payload or {})
    if cleanPayload == nil then return nil, payloadError or "Payload is not safely serializable" end
    sentAt = sentAt == nil and (os.epoch("utc") / 1000) or sentAt
    if not finite(sentAt) or sentAt < 0 then return nil, "sentAt must be a valid timestamp" end

    local message = {
        helios = true,
        contract = protocol.name,
        contractVersion = protocol.version,
        kind = kind,
        source = cleanSource,
        sequence = sequence,
        sentAt = sentAt,
        payload = cleanPayload,
    }
    message.messageId = protocol.messageId(message)
    return message
end

function protocol.validate(message, expectedKind)
    if type(message) ~= "table" or message.helios ~= true then
        return nil, "Not a HELIOS facility message"
    end
    if message.contract ~= protocol.name or message.contractVersion ~= protocol.version then
        return nil, "Unsupported facility contract"
    end
    if not kinds[message.kind] or (expectedKind and message.kind ~= expectedKind) then
        return nil, "Unexpected facility message kind"
    end
    local source, sourceError = validateSource(message.source)
    if not source then return nil, sourceError end
    if not validSequence(message.sequence) then return nil, "Invalid facility sequence" end
    if not finite(message.sentAt) or message.sentAt < 0 then
        return nil, "Invalid facility timestamp"
    end
    local payload, payloadError = sanitize(message.payload or {})
    if payload == nil then return nil, payloadError or "Unsafe facility payload" end

    local clean = {
        helios = true,
        contract = protocol.name,
        contractVersion = protocol.version,
        kind = message.kind,
        source = source,
        sequence = message.sequence,
        sentAt = message.sentAt,
        payload = payload,
    }
    clean.messageId = protocol.messageId(clean)
    if message.messageId ~= nil and message.messageId ~= clean.messageId then
        return nil, "Facility messageId does not match its source and sequence"
    end
    return clean
end

function protocol.acknowledge(message, source, sequence, status, detail, sentAt)
    local original, reason = protocol.validate(message)
    if not original then return nil, reason end
    status = status or "accepted"
    if status ~= "accepted" and status ~= "rejected" and status ~= "duplicate" then
        return nil, "Unsupported acknowledgement status"
    end
    return protocol.make("acknowledgement", source, sequence, {
        messageId = original.messageId,
        status = status,
        detail = detail and tostring(detail) or nil,
    }, sentAt)
end

function protocol.newSequenceTracker()
    return { sessions = {} }
end

function protocol.acceptSequence(tracker, message)
    if type(tracker) ~= "table" or type(tracker.sessions) ~= "table" then
        return false, "Invalid sequence tracker"
    end
    local clean, reason = protocol.validate(message)
    if not clean then return false, reason end
    local key = tostring(clean.source.computerId) .. ":" .. clean.source.sessionId
    local previous = tracker.sessions[key]
    if previous ~= nil and clean.sequence <= previous then
        return false, clean.sequence == previous and "duplicate" or "stale"
    end
    tracker.sessions[key] = clean.sequence
    return true, clean
end

function protocol.describe()
    local supported = {}
    for kind in pairs(kinds) do supported[#supported + 1] = kind end
    table.sort(supported)
    return {
        name = protocol.name,
        version = protocol.version,
        rednetProtocol = protocol.rednetProtocol,
        messageKinds = supported,
        remoteCommands = false,
    }
end

return protocol
