-- @section MODULE PACK MANIFEST
local loader = {}
local ROOT = "/helios/modules"
local MANIFEST_PATH = ROOT .. "/manifest.json"

local manifestCache

local function readFile(path)
    local handle, reason = fs.open(path, "r")
    if not handle then return nil, reason end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function safeRelativePath(path)
    return type(path) == "string" and path ~= "" and
        string.sub(path, 1, 1) ~= "/" and
        not string.find(path, "..", 1, true) and
        not string.find(path, "\\", 1, true)
end

local function validateManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       type(manifest.pack) ~= "table" or type(manifest.pack.version) ~= "string" or
       type(manifest.compatible_core_versions) ~= "table" or
       type(manifest.modules) ~= "table" then
        return false, "Module manifest uses an unsupported schema"
    end
    local moduleIds, capabilities = {}, {}
    for _, module in ipairs(manifest.modules) do
        if type(module) ~= "table" or type(module.id) ~= "string" or module.id == "" or
           type(module.name) ~= "string" or type(module.version) ~= "string" or
           type(module.provides) ~= "table" then
            return false, "Module manifest contains invalid module metadata"
        end
        if moduleIds[module.id] then
            return false, "Module manifest duplicates module id " .. module.id
        end
        moduleIds[module.id] = true
        for _, provider in ipairs(module.provides) do
            if type(provider) ~= "table" or type(provider.capability) ~= "string" or
               provider.capability == "" or not safeRelativePath(provider.path) then
                return false, "Module manifest contains an invalid capability provider"
            end
            if capabilities[provider.capability] then
                return false, "Module manifest duplicates capability " .. provider.capability
            end
            capabilities[provider.capability] = true
        end
    end
    return true
end

local function coreCompatible(manifest, coreVersion)
    if not coreVersion then return true end
    for _, version in ipairs(manifest.compatible_core_versions or {}) do
        if version == coreVersion then return true end
    end
    return false
end

function loader.manifest(coreVersion)
    if not manifestCache then
        local encoded, reason = readFile(MANIFEST_PATH)
        if not encoded then return nil, "Module manifest unavailable: " .. tostring(reason) end
        local ok, decoded = pcall(textutils.unserializeJSON, encoded)
        if not ok or type(decoded) ~= "table" then
            return nil, "Module manifest is invalid JSON"
        end
        local valid, validationReason = validateManifest(decoded)
        if not valid then return nil, validationReason end
        manifestCache = decoded
    end
    if not coreCompatible(manifestCache, coreVersion) then
        return nil, "Module Pack " .. tostring((manifestCache.pack or {}).version or "unknown") ..
            " is not compatible with HELIOS Core " .. tostring(coreVersion)
    end
    return manifestCache
end

-- @section MODULE RESOLUTION AND LOADING
function loader.resolve(capability, coreVersion)
    local manifest, reason = loader.manifest(coreVersion)
    if not manifest then return nil, reason end
    for _, module in ipairs(manifest.modules) do
        for _, provider in ipairs(module.provides or {}) do
            if provider.capability == capability then
                if not safeRelativePath(provider.path) then
                    return nil, "Module path is unsafe: " .. tostring(provider.path)
                end
                return {
                    path = ROOT .. "/" .. provider.path,
                    capability = capability,
                    moduleId = module.id,
                    moduleName = module.name,
                    moduleVersion = module.version,
                    packVersion = manifest.pack.version,
                }
            end
        end
    end
    return nil, "No installed HELIOS module provides " .. tostring(capability)
end

function loader.load(capability, coreVersion)
    local resolved, reason = loader.resolve(capability, coreVersion)
    if not resolved then return nil, reason end
    if not fs.exists(resolved.path) then
        return nil, "Module file is missing: " .. resolved.path
    end
    local ok, implementation = pcall(dofile, resolved.path)
    if not ok then return nil, "Module failed to load: " .. tostring(implementation) end
    if type(implementation) ~= "table" then
        return nil, "Module did not return an adapter table: " .. resolved.path
    end
    return implementation, resolved
end

function loader.versions(coreVersion)
    local manifest, reason = loader.manifest(coreVersion)
    if not manifest then return nil, reason end
    local versions = {
        pack = manifest.pack.version,
        modules = {},
    }
    for _, module in ipairs(manifest.modules) do
        versions.modules[#versions.modules + 1] = {
            id = module.id,
            name = module.name,
            version = module.version,
        }
    end
    return versions
end

return loader
