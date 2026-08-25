local contract = {}

contract.name = "helios.ui"
contract.version = 1

local commands = {
    ["navigate"] = { authority = "local", confirmation = false },
    ["alarm.silence"] = { authority = "operator", confirmation = false },
    ["control.set_authority"] = { authority = "operator", confirmation = true },
    ["reactor.set_active"] = { authority = "manual", confirmation = false },
    ["reactor.adjust_rods"] = { authority = "manual", confirmation = false },
    ["turbine.set_active"] = { authority = "manual", confirmation = false },
    ["turbine.adjust_flow"] = { authority = "manual", confirmation = false },
}

local function copySafe(value, seen)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
        return value
    end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local safeKey = copySafe(key, seen)
        local safeValue = copySafe(item, seen)
        if safeKey ~= nil and safeValue ~= nil then result[safeKey] = safeValue end
    end
    seen[value] = nil
    return result
end

function contract.describe()
    return {
        name = contract.name,
        version = contract.version,
        commands = copySafe(commands),
        guarantees = {
            telemetryOnly = true,
            noHardwareHandles = true,
            guardedCommandDispatch = true,
            textFallback = true,
        },
    }
end

function contract.attach(snapshot)
    local safe = copySafe(snapshot or {})
    safe.uiContract = contract.describe()
    return safe
end

function contract.validateCommand(envelope)
    if type(envelope) ~= "table" then return nil, "Command envelope must be a table" end
    local name = tostring(envelope.name or "")
    local descriptor = commands[name]
    if not descriptor then return nil, "Unsupported UI command: " .. name end
    if envelope.target ~= nil and type(envelope.target) ~= "string" then
        return nil, "Command target must be a string"
    end
    if envelope.arguments ~= nil and type(envelope.arguments) ~= "table" then
        return nil, "Command arguments must be a table"
    end
    return {
        name = name,
        target = envelope.target,
        arguments = copySafe(envelope.arguments or {}),
        confirmed = envelope.confirmed == true,
        descriptor = copySafe(descriptor),
    }
end

function contract.authorize(command, context)
    context = context or {}
    local authority = command.descriptor.authority
    if authority == "local" then return true end
    if context.remote == true then return false, "Remote UI is read-only" end
    if context.idConflict == true then return false, "Computer ID conflict blocks commands" end
    if authority == "manual" and context.controlMode ~= "manual" then
        return false, "Manual authority is required"
    end
    if command.descriptor.confirmation and command.confirmed ~= true then
        return false, "Operator confirmation is required"
    end
    return true
end

function contract.dispatch(envelope, context, handlers)
    local command, validationError = contract.validateCommand(envelope)
    if not command then return false, validationError end
    local authorized, authorizationError = contract.authorize(command, context)
    if not authorized then return false, authorizationError end
    local handler = type(handlers) == "table" and handlers[command.name] or nil
    if type(handler) ~= "function" then return false, "No guarded handler is registered" end
    return handler(command.target, command.arguments, command)
end

return contract
