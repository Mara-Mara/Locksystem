local PLUGIN = PLUGIN

--[[
    Door Locks - server logic
    Handles:
      - Lock registry and persistence
      - Core lock/unlock / removal
      - Deadlock entity management
      - Door interaction hooks and net handlers
]]

-- network strings used by this plugin (register on plugin load)
if (SERVER) then
    util.AddNetworkString("ixDoorLocks_OpenPlacement")
    util.AddNetworkString("ixDoorLocks_ConfirmPlacement")
    util.AddNetworkString("ixDoorLocks_OpenMenu")
    util.AddNetworkString("ixDoorLocks_DoAction")
    util.AddNetworkString("ixDoorLocks_SubmitCode")
    util.AddNetworkString("ixDoorLocks_RequestMenu")
    util.AddNetworkString("ixDoorLocks_QuickToggle")
    util.AddNetworkString("ixDoorLocks_BiometricUserList")
    util.AddNetworkString("ixDoorLocks_KeycardPrintMenu")
    util.AddNetworkString("ixDoorLocks_KeycardPrintConfirm")
    util.AddNetworkString("ixDoorLocks_KeycardManage")
    util.AddNetworkString("ixDoorLocks_KeycardView")
    util.AddNetworkString("ixDoorLocks_KeycardStoryMenu")
    util.AddNetworkString("ixDoorLocks_KeycardStoryConfirm")
    util.AddNetworkString("ixDoorLocks_PlaySound")
    util.AddNetworkString("ixDoorLocks_AddDoorToPlacement")
    util.AddNetworkString("ixDoorLocks_FinalizePlacement")
    util.AddNetworkString("ixDoorLocks_CancelPlacement")
    util.AddNetworkString("ixDoorLocks_UndoLastSelection")
    util.AddNetworkString("ixDoorLocks_SetGroupCode")
    util.AddNetworkString("ixDoorLocks_ClearGroupCode")
    util.AddNetworkString("ixDoorLocks_ViewGroupLocks")
end

PLUGIN.lockTypes = {
    DIGILOCK = "digilock",
    DEADLOCK = "deadlock",
}

PLUGIN.lockModes = {
    CODE = "code",
    KEYCARD = "keycard",
    BIOMETRIC = "biometric",
}

-- Helper function to check if a client is an admin (defined early so it can be used throughout)
local function isAdmin(client)
    return IsValid(client) and (client:IsAdmin() or client:IsSuperAdmin())
end

-- In‑memory lock registry, restored on LoadData.
PLUGIN.locks = PLUGIN.locks or {}

-- quick lookup from doorID -> {digilock = lockID, deadlock = lockID}
PLUGIN.doorIndex = PLUGIN.doorIndex or {}

-- Multi-door placement sessions: clientID -> {lockType, itemID, doorIDs = {}, traceData}
PLUGIN.placementSessions = PLUGIN.placementSessions or {}

-- basic configuration, can be overridden from schema configs if desired
PLUGIN.config = PLUGIN.config or {}

PLUGIN.config.deadlockMaxHealth = PLUGIN.config.deadlockMaxHealth or 100
PLUGIN.config.maxKeycardsPerLock = PLUGIN.config.maxKeycardsPerLock or 10
PLUGIN.config.maxBiometricUsers = PLUGIN.config.maxBiometricUsers or 16
PLUGIN.config.pairingDuration = PLUGIN.config.pairingDuration or 30 -- seconds
PLUGIN.config.allowAnyoneToLock = PLUGIN.config.allowAnyoneToLock or false

-- basic helper for hashing numerical codes, do not store plain text
function PLUGIN:HashCode(raw)
    if (not raw or raw == "") then return nil end

    raw = tostring(raw)

    -- simple CRC with a salt so codes are not trivially shared between servers
    local salt = "ix_doorlocks_salt"
    return util.CRC(salt .. raw)
end

-- Helper: get a stable numeric ID for a door entity.
-- For map doors, uses MapCreationID. For dynamically spawned doors (Door Tool), uses a custom ID system.
-- For double doors, both leaves are mapped to the same ID.
function PLUGIN:GetDoorID(door)
    if (not IsValid(door) or not door:IsDoor()) then return end

    -- Try MapCreationID first (for map-spawned doors)
    local id = door:MapCreationID()

    -- If no MapCreationID (Door Tool doors), use custom ID system
    if (not id or id <= 0) then
        -- Check if door already has a custom ID stored
        if (not door.ixDoorLockID) then
            -- Generate a stable unique ID based on entity index
            -- Use negative numbers to distinguish from map IDs
            -- Entity index is stable for the lifetime of the entity
            door.ixDoorLockID = -door:EntIndex()
        end
        id = door.ixDoorLockID
    end

    local partner = door.GetDoorPartner and door:GetDoorPartner() or nil
    if (IsValid(partner)) then
        local pid = nil
        
        -- Try MapCreationID for partner
        if (partner.MapCreationID) then
            pid = partner:MapCreationID()
        end
        
        -- If no MapCreationID, use custom ID
        if (not pid or pid <= 0) then
            if (not partner.ixDoorLockID) then
                partner.ixDoorLockID = -partner:EntIndex()
            end
            pid = partner.ixDoorLockID
        end
        
        if (pid and (not id or pid < id)) then
            id = pid
            -- Ensure both doors share the same ID
            door.ixDoorLockID = id
            partner.ixDoorLockID = id
        end
    end

    if (id) then
        return id
    end
end

-- Helper: generate a stable lockID string.
function PLUGIN:GenerateLockID(doorID, lockType)
    return string.format("%s:%s:%s", game.GetMap() or "map", tostring(doorID or 0), lockType or "unknown")
end

function PLUGIN:GetLock(lockID)
    return self.locks[lockID]
end

function PLUGIN:GetDoorLock(door, lockType)
    local doorID = self:GetDoorID(door)
    if (not doorID) then return end

    local entry = self.doorIndex[doorID]
    if (not entry) then return end

    if (lockType == self.lockTypes.DIGILOCK) then
        return self.locks[entry.digilock]
    elseif (lockType == self.lockTypes.DEADLOCK) then
        return self.locks[entry.deadlock]
    end
end

local function ensureSet(tableObj, key)
    if (not tableObj[key]) then
        tableObj[key] = {}
    end
    return tableObj[key]
end

-- Register a newly created lock in memory and index it.
function PLUGIN:RegisterLock(lockData)
    local lockID = lockData.lockID
    self.locks[lockID] = lockData

    -- Support multiple doors: register lock for all doorIDs
    local doorIDs = lockData.doorIDs or {lockData.doorID} -- Backward compatibility
    
    for _, doorID in ipairs(doorIDs) do
        if (doorID) then
            self.doorIndex[doorID] = self.doorIndex[doorID] or {}

            if (lockData.type == self.lockTypes.DIGILOCK) then
                self.doorIndex[doorID].digilock = lockID
            elseif (lockData.type == self.lockTypes.DEADLOCK) then
                self.doorIndex[doorID].deadlock = lockID
            end
        end
    end

    self:SaveData()
end

-- Remove a lock from memory and door index. Does not touch entities.
function PLUGIN:UnregisterLock(lockID)
    local data = self.locks[lockID]
    if (not data) then return end

    -- Support multiple doors: unregister from all doorIDs
    local doorIDs = data.doorIDs or {data.doorID} -- Backward compatibility
    
    for _, doorID in ipairs(doorIDs) do
        if (doorID and self.doorIndex[doorID]) then
            if (self.doorIndex[doorID].digilock == lockID) then
                self.doorIndex[doorID].digilock = nil
            end
            if (self.doorIndex[doorID].deadlock == lockID) then
                self.doorIndex[doorID].deadlock = nil
            end
            if (not next(self.doorIndex[doorID])) then
                self.doorIndex[doorID] = nil
            end
        end
    end

    self.locks[lockID] = nil
    self:SaveData()
end

-- Helper: fetch door entity from stored doorID.
function PLUGIN:GetDoorFromID(doorID)
    if (not doorID) then return end
    
    -- Try map entity first (for map-spawned doors with positive IDs)
    if (doorID > 0) then
        local ent = ents.GetMapCreatedEntity(doorID)
        if (IsValid(ent) and ent:IsDoor()) then
            return ent
        end
    end
    
    -- For custom IDs (Door Tool doors with negative IDs), search all doors
    if (doorID < 0) then
        for _, ent in ipairs(ents.GetAll()) do
            if (IsValid(ent) and ent:IsDoor() and ent.ixDoorLockID == doorID) then
                return ent
            end
        end
    end
end

-- Lock / unlock helpers that affect the door entity.
function PLUGIN:LockDoorEntity(door, lockID)
    if (not IsValid(door) or not door:IsDoor()) then return end

    door.ixDoorLockedByLock = lockID
    door:Fire("lock")
    -- Removed auto-close: doors will not automatically close when locked

    local partner = door.GetDoorPartner and door:GetDoorPartner() or nil
    if (IsValid(partner)) then
        partner:Fire("lock")
        -- Removed auto-close for partner door as well
    end
end

function PLUGIN:UnlockDoorEntity(door, lockID)
    if (not IsValid(door) or not door:IsDoor()) then return end

    if (door.ixDoorLockedByLock == lockID) then
        door.ixDoorLockedByLock = nil
    end

    door:Fire("unlock")

    local partner = door.GetDoorPartner and door:GetDoorPartner() or nil
    if (IsValid(partner)) then
        partner:Fire("unlock")
    end
end

-- Apply current state for a single lock after loading.
function PLUGIN:ApplyLockState(lockID)
    local data = self.locks[lockID]
    if (not data) then return end

    -- Support multiple doors: apply state to all doors
    local doorIDs = data.doorIDs or {data.doorID} -- Backward compatibility
    
    for _, doorID in ipairs(doorIDs) do
        local door = self:GetDoorFromID(doorID)
        if (IsValid(door)) then
            if (data.isLocked) then
                self:LockDoorEntity(door, lockID)
            else
                self:UnlockDoorEntity(door, lockID)
            end
        end
    end

    -- Deadlock entity only on first door
    if (data.type == self.lockTypes.DEADLOCK and not data.wasDestroyed) then
        self:EnsureDeadlockEntity(lockID)
    end
end

function PLUGIN:ApplyAllLocks()
    for lockID, _ in pairs(self.locks) do
        self:ApplyLockState(lockID)
    end
end

-- Ensure that a Deadlock entity exists for the given lockID.
function PLUGIN:EnsureDeadlockEntity(lockID)
    local data = self.locks[lockID]
    if (not data) then return end
    if (data.type ~= self.lockTypes.DEADLOCK) then return end
    if (data.wasDestroyed) then return end

    if (IsValid(data.entity) and data.entity:GetClass() == "ix_deadlock") then
        return
    end

    local door = self:GetDoorFromID(data.doorID)
    if (not IsValid(door)) then return end

    local pos, ang
    if (data.doorLocalPos and data.doorLocalAng) then
        pos = door:LocalToWorld(data.doorLocalPos)
        ang = door:LocalToWorldAngles(data.doorLocalAng)
    else
        pos = data.pos or door:GetPos()
        ang = data.angles or door:GetAngles()
    end

    local ent = ents.Create("ix_deadlock")
    if (not IsValid(ent)) then return end

    ent:SetPos(pos)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()

    ent:SetDoor(door, pos, ang)
    ent:SetLockID(lockID)

    data.entity = ent
end

-- Create a logical lock (used by items and admin commands).
function PLUGIN:CreateLock(client, door, lockType, mode, options)
    options = options or {}

    local doorID = self:GetDoorID(door)
    if (not doorID) then
        return nil, "invalidDoor"
    end

    -- Enforce per-door uniqueness per type.
    local existing = self:GetDoorLock(door, lockType)
    if (existing) then
        return nil, "alreadyHasLock"
    end

    -- Support multiple doors: use first doorID for lockID generation, but store all doorIDs
    local primaryDoorID = doorID
    local doorIDs = options.doorIDs or {doorID} -- Support both single and multi-door
    
    local lockID = self:GenerateLockID(primaryDoorID, lockType)

    local lockData = {
        lockID = lockID,
        type = lockType,
        mode = mode,

        doorID = primaryDoorID, -- Primary door (for backward compatibility)
        doorIDs = doorIDs, -- All doors controlled by this lock
        isLocked = true,

        installedByCharID = IsValid(client) and client:GetCharacter() and client:GetCharacter():GetID() or nil,
        createdAt = os.time(),
        itemUniqueID = options.itemUniqueID or nil, -- Store item uniqueID for returning on removal

        authorizedChars = {},
        authorizedBiometric = {},
        biometricManagers = {}, -- Separate list for biometric managers
        failedAttempts = 0,
        pairingActive = false,
        pairingMode = nil, -- "regular" or "manager" for biometric pairing
        groupCode = nil, -- Group code for linking locks of the same mode
    }

    -- Initial authorization: installer (lock placer) is always authorized.
    if (lockData.installedByCharID) then
        lockData.authorizedChars[lockData.installedByCharID] = true
    end

    if (mode == self.lockModes.CODE) then
        lockData.userCodeHash = options.userCodeHash or nil
        lockData.managerCodeHash = options.managerCodeHash or options.masterCodeHash or nil -- Support old masterCodeHash for backwards compatibility
    elseif (mode == self.lockModes.KEYCARD) then
        lockData.keycards = options.keycards or {}
        lockData.nextSerialNumber = 1 -- Linear serial number counter
    elseif (mode == self.lockModes.BIOMETRIC) then
        if (lockData.installedByCharID) then
            lockData.authorizedBiometric[lockData.installedByCharID] = true
            -- Installer is NOT added to biometricManagers - they are a master (installer) not a manager
            -- Only admins and managers can be in biometricManagers
        end
    end

    if (lockType == self.lockTypes.DEADLOCK) then
        lockData.deadlockHealth = self.config.deadlockMaxHealth

        -- optional initial transform information if provided
        if (options.pos and options.angles) then
            lockData.pos = options.pos
            lockData.angles = options.angles

            if (IsValid(door)) then
                lockData.doorLocalPos = door:WorldToLocal(options.pos)
                lockData.doorLocalAng = door:WorldToLocalAngles(options.angles)
            end
        end
    end

    self:RegisterLock(lockData)

    -- Apply initial state and ensure entities.
    self:ApplyLockState(lockID)

    return lockData
end

-- Public server API for toggling and removing locks.
function PLUGIN:SetLockState(lockID, bLocked)
    local data = self.locks[lockID]
    if (not data) then return end

    data.isLocked = bLocked and true or false

    -- Support multiple doors: apply state to all doors
    local doorIDs = data.doorIDs or {data.doorID} -- Backward compatibility
    
    for _, doorID in ipairs(doorIDs) do
        local door = self:GetDoorFromID(doorID)
        if (IsValid(door)) then
            if (data.isLocked) then
                self:LockDoorEntity(door, lockID)
            else
                self:UnlockDoorEntity(door, lockID)
            end
        end
    end
    
    -- Auto-relock timer (only one timer per lock, not per door)
    if (data.isLocked) then
        -- Cancel auto-relock timer if locking
        if (data.autoRelockTimer) then
            timer.Remove(data.autoRelockTimer)
            data.autoRelockTimer = nil
        end
    else
        -- Auto-relock after 60 seconds
        if (data.autoRelockTimer) then
            timer.Remove(data.autoRelockTimer)
        end
        data.autoRelockTimer = "ixDoorLocks_AutoRelock_" .. lockID
        timer.Create(data.autoRelockTimer, 60, 1, function()
            if (not ix.shuttingDown and data and not data.isLocked) then
                PLUGIN:SetLockState(lockID, true)
            end
        end)
    end

    self:SaveData()
end

function PLUGIN:RemoveLock(lockID, unlockDoor, charID)
    local data = self.locks[lockID]
    if (not data) then return end

    -- Support multiple doors: unlock all doors
    local doorIDs = data.doorIDs or {data.doorID} -- Backward compatibility
    
    if (unlockDoor) then
        for _, doorID in ipairs(doorIDs) do
            local door = self:GetDoorFromID(doorID)
            if (IsValid(door)) then
                self:UnlockDoorEntity(door, lockID)
            end
        end
    end

    if (data.type == self.lockTypes.DEADLOCK and IsValid(data.entity)) then
        data.entity.bShouldBreak = false
        data.entity:Remove()
    end

    -- Return the lock item to the player
    if (charID) then
        local char = ix.char.loaded[charID]
        if (char) then
            local inventory = char:GetInventory()
            if (inventory) then
                local itemUniqueID = data.itemUniqueID or (data.type == self.lockTypes.DIGILOCK and "digilock" or "deadlock")
                if (inventory:Add(itemUniqueID, 1) == false) then
                    -- Inventory full, spawn on ground
                    local client = char:GetPlayer()
                    if (IsValid(client)) then
                        ix.item.Spawn(itemUniqueID, client, nil, nil)
                    end
                end
            end
        end
    end

    self:UnregisterLock(lockID)
end

-- Persistence
function PLUGIN:SaveData()
    -- Strip runtime-only fields before saving.
    local save = {
        locks = {},
    }

    for lockID, data in pairs(self.locks) do
        save.locks[lockID] = {
            lockID = data.lockID,
            type = data.type,
            mode = data.mode,

            doorID = data.doorID,
            doorIDs = data.doorIDs, -- Multi-door support
            isLocked = data.isLocked,

            installedByCharID = data.installedByCharID,
            createdAt = data.createdAt,
            itemUniqueID = data.itemUniqueID,

            authorizedChars = data.authorizedChars or {},
            authorizedBiometric = data.authorizedBiometric or {},
            failedAttempts = data.failedAttempts or 0,

            userCodeHash = data.userCodeHash,
            managerCodeHash = data.managerCodeHash or data.masterCodeHash, -- Support old masterCodeHash
            masterGranted = data.masterGranted or {},
            keycards = data.keycards or {},
            nextSerialNumber = data.nextSerialNumber or 1,

            pairingActive = false,
            pairingUntil = nil,
            pairingMode = nil,
            biometricManagers = data.biometricManagers or {},
            biometricInactive = data.biometricInactive or {},

            deadlockHealth = data.deadlockHealth,
            wasDestroyed = data.wasDestroyed or false,

            pos = data.pos,
            angles = data.angles,
            doorLocalPos = data.doorLocalPos,
            doorLocalAng = data.doorLocalAng,
            groupCode = data.groupCode, -- Group code for linking locks
        }
    end

    self:SetData(save)
end

function PLUGIN:LoadData()
    self.locks = {}
    self.doorIndex = {}

    local data = self:GetData() or {}
    local stored = data.locks or {}

    for lockID, lockData in pairs(stored) do
        self.locks[lockID] = table.Copy(lockData)

        local doorID = lockData.doorID
        if (doorID) then
            self.doorIndex[doorID] = self.doorIndex[doorID] or {}
            if (lockData.type == self.lockTypes.DIGILOCK) then
                self.doorIndex[doorID].digilock = lockID
            elseif (lockData.type == self.lockTypes.DEADLOCK) then
                self.doorIndex[doorID].deadlock = lockID
            end
        end
    end

    -- Delay application until after all entities have spawned.
    timer.Simple(0, function()
        if (not ix.shuttingDown) then
            self:ApplyAllLocks()
        end
    end)
end

-- Deadlock damage hook helper, used from the entity.
function PLUGIN:OnDeadlockDamaged(lockID, dmgInfo)
    local data = self.locks[lockID]
    if (not data or data.type ~= self.lockTypes.DEADLOCK) then return end

    if (data.wasDestroyed) then return end

    data.deadlockHealth = (data.deadlockHealth or self.config.deadlockMaxHealth) - dmgInfo:GetDamage()

    if (data.deadlockHealth <= 0) then
        data.wasDestroyed = true

        local door = self:GetDoorFromID(data.doorID)
        if (IsValid(door)) then
            self:UnlockDoorEntity(door, lockID)
        end

        if (IsValid(data.entity)) then
            data.entity.bShouldBreak = true
            data.entity:Remove()
        end
    end

    self:SaveData()
end

-- Called when a Deadlock entity updates its transform; keeps data in sync.
function PLUGIN:OnDeadlockTransformChanged(lockID, door, pos, ang)
    local data = self.locks[lockID]
    if (not data) then return end

    data.pos = pos
    data.angles = ang

    if (IsValid(door)) then
        data.doorLocalPos = door:WorldToLocal(pos)
        data.doorLocalAng = door:WorldToLocalAngles(ang)
    end

    self:SaveData()
end

-- Placement flow -------------------------------------------------------------

-- Start placement from an item; adds door to selection or opens menu if first door.
function PLUGIN:BeginPlacement(client, door, lockType, itemID, traceData)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local doorID = self:GetDoorID(door)
    if (not doorID) then
        client:Notify("Could not identify door ID.")
        return
    end

    -- Check if door already has this type of lock
    local existing = self:GetDoorLock(door, lockType)
    if (existing) then
        client:Notify("This door already has that type of lock.")
        return
    end

    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local session = PLUGIN.placementSessions[clientID]

    -- If no active session, start one
    if (not session) then
        session = {
            lockType = lockType,
            itemID = itemID,
            doorIDs = {},
            traceData = traceData
        }
        PLUGIN.placementSessions[clientID] = session
    elseif (session.lockType ~= lockType) then
        client:Notify("You have an active placement session for a different lock type. Cancel it first.")
        return
    elseif (session.itemID ~= itemID) then
        client:Notify("You have an active placement session with a different item. Cancel it first.")
        return
    end

    -- Check if door is already in selection
    for _, id in ipairs(session.doorIDs) do
        if (id == doorID) then
            client:Notify("This door is already in your selection.")
            return
        end
    end

    -- Add door to selection
    table.insert(session.doorIDs, doorID)
    client:Notify(string.format("Door added to selection (%d door(s) selected). Look at another door and press 'Place' again, or use 'Finalize Placement' when ready.", #session.doorIDs))
end

-- Finalize placement: open the placement menu with all selected doors
net.Receive("ixDoorLocks_FinalizePlacement", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local session = PLUGIN.placementSessions[clientID]
    
    if (not session or #session.doorIDs == 0) then
        client:Notify("No active placement session.")
        return
    end

    -- Get the first door for the menu (we'll use it for trace data and UI)
    local firstDoorID = session.doorIDs[1]
    local firstDoor = PLUGIN:GetDoorFromID(firstDoorID)
    
    if (not IsValid(firstDoor)) then
        client:Notify("Could not find first door in selection.")
        PLUGIN.placementSessions[clientID] = nil
        return
    end

    -- Open placement menu (will use first door for UI, but we'll store all doorIDs)
    net.Start("ixDoorLocks_OpenPlacement")
        net.WriteEntity(firstDoor)
        net.WriteString(session.lockType)
        net.WriteUInt(session.itemID or 0, 32)
        -- Send trace data for deadlocks (from first door)
        if (session.lockType == PLUGIN.lockTypes.DEADLOCK and session.traceData) then
            net.WriteBool(true)
            net.WriteVector(session.traceData.hitPos or Vector(0, 0, 0))
            net.WriteVector(session.traceData.hitNormal or Vector(0, 0, 0))
        else
            net.WriteBool(false)
        end
        -- Send number of doors in selection (0 means single door mode for backward compatibility)
        net.WriteUInt(#session.doorIDs > 1 and #session.doorIDs or 0, 8)
        -- Send all doorIDs if multi-door
        if (#session.doorIDs > 1) then
            for _, doorID in ipairs(session.doorIDs) do
                net.WriteUInt(doorID, 32)
            end
        end
    net.Send(client)
end)

-- Cancel placement session
net.Receive("ixDoorLocks_CancelPlacement", function(_, client)
    if (not IsValid(client)) then return end

    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local session = PLUGIN.placementSessions[clientID]
    if (session) then
        PLUGIN.placementSessions[clientID] = nil
        client:Notify("Placement session cancelled.")
        
        -- Clear placement flag from item
        if (session.itemID) then
            local item = ix.item.instances[session.itemID]
            if (item) then
                item:SetData("placementActive", false)
            end
        end
    end
end)

-- Undo last door selection
net.Receive("ixDoorLocks_UndoLastSelection", function(_, client)
    if (not IsValid(client)) then return end

    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local session = PLUGIN.placementSessions[clientID]
    
    if (not session) then
        client:Notify("No active placement session.")
        return
    end

    if (#session.doorIDs == 0) then
        client:Notify("No doors in selection to undo.")
        return
    end

    local removedDoorID = table.remove(session.doorIDs)
    
    if (#session.doorIDs == 0) then
        -- No more doors, cancel the session
        PLUGIN.placementSessions[clientID] = nil
        client:Notify("Last door removed. Placement session cancelled.")
        
        -- Clear placement flag from item
        if (session.itemID) then
            local item = ix.item.instances[session.itemID]
            if (item) then
                item:SetData("placementActive", false)
            end
        end
    else
        client:Notify(string.format("Last door removed. %d door(s) remaining in selection.", #session.doorIDs))
    end
end)

-- Client confirmed a placement choice (mode and initial data).
net.Receive("ixDoorLocks_ConfirmPlacement", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local door = net.ReadEntity()
    local lockType = net.ReadString()
    local modeStr = net.ReadString()
    local itemID = net.ReadUInt(32)
    local userCode = net.ReadString() or ""
    local masterCode = net.ReadString() or ""
    local hasTraceData = net.ReadBool()
    local traceHitPos = hasTraceData and net.ReadVector() or nil
    local traceHitNormal = hasTraceData and net.ReadVector() or nil
    
    -- Read multi-door selection (if present)
    local hasMultiDoor = net.ReadBool()
    local doorIDs = {}
    if (hasMultiDoor) then
        local doorCount = net.ReadUInt(8)
        for i = 1, doorCount do
            table.insert(doorIDs, net.ReadUInt(32))
        end
    else
        -- Single door mode (backward compatibility)
        if (IsValid(door) and door:IsDoor()) then
            local doorID = PLUGIN:GetDoorID(door)
            if (doorID) then
                table.insert(doorIDs, doorID)
            end
        end
    end

    if (#doorIDs == 0) then
        client:Notify("No valid doors in selection.")
        return
    end

    local char = client:GetCharacter()
    if (not char) then return end

    local inventory = char:GetInventory()
    if (not inventory) then return end

    local item = ix.item.instances[itemID]
    if (not item or item.invID ~= inventory:GetID()) then
        return
    end

    local itemUniqueID = item.uniqueID -- Store for returning on removal

    -- map string to mode constant
    local mode
    modeStr = string.lower(modeStr or "")
    if (modeStr == "code") then
        mode = PLUGIN.lockModes.CODE
    elseif (modeStr == "keycard") then
        mode = PLUGIN.lockModes.KEYCARD
    elseif (modeStr == "biometric") then
        mode = PLUGIN.lockModes.BIOMETRIC
    else
        client:Notify("Invalid lock mode.")
        return
    end

    -- for code mode, require a non-empty user code
    local options = {
        itemUniqueID = itemUniqueID -- Store item uniqueID for returning on removal
    }
    if (mode == PLUGIN.lockModes.CODE) then
        if (userCode == "" or userCode == nil) then
            client:Notify("You must enter a user code.")
            return
        end
        options.userCodeHash = PLUGIN:HashCode(userCode)
        if (masterCode and masterCode ~= "") then
            options.managerCodeHash = PLUGIN:HashCode(masterCode)
        end
    end

    -- Get first door for trace data (deadlocks need position)
    local firstDoor = PLUGIN:GetDoorFromID(doorIDs[1])
    
    -- for deadlocks, use trace position if available, otherwise compute default
    if (lockType == PLUGIN.lockTypes.DEADLOCK and IsValid(firstDoor)) then
        if (traceHitPos and traceHitNormal) then
            -- Offset position slightly along normal to prevent clipping into door
            local offsetDistance = 2.0 -- Offset by 2 units from door surface
            local pos = traceHitPos + traceHitNormal * offsetDistance
            
            -- Calculate angles from hit normal
            local normal = traceHitNormal:Angle()
            -- Rotate to face away from door surface
            normal:RotateAroundAxis(normal:Forward(), 180)
            normal:RotateAroundAxis(normal:Right(), 180)
            
            options.pos = pos
            options.angles = normal
        else
            -- Fallback to default position calculation
            local entDef = scripted_ents.Get("ix_deadlock")
            if (entDef and entDef.GetLockPosition) then
                local pos, ang = entDef:GetLockPosition(firstDoor)
                options.pos = pos
                options.angles = ang
            end
        end
    end

    -- Pass doorIDs to CreateLock
    options.doorIDs = doorIDs
    
    local lockData, err = PLUGIN:CreateLock(client, firstDoor, lockType, mode, options)
    if (not lockData) then
        if (err == "alreadyHasLock") then
            client:Notify("This door already has that type of lock.")
        else
            client:Notify("Failed to place lock.")
        end
        return
    end

    -- initial keycard for keycard mode: give the installer a master card (Serial 1)
    if (mode == PLUGIN.lockModes.KEYCARD) then
        lockData.keycards = lockData.keycards or {}
        lockData.nextSerialNumber = lockData.nextSerialNumber or 1

        if (#lockData.keycards < PLUGIN.config.maxKeycardsPerLock) then
            local serial = lockData.nextSerialNumber
            lockData.nextSerialNumber = serial + 1
            local keyUID = tostring(util.CRC(lockData.lockID .. os.time() .. math.random()))
            
            table.insert(lockData.keycards, {
                serialNumber = serial,
                keyUID = keyUID,
                cardType = "master",
                cardName = "Master",
                active = true
            })

            if (inventory:Add("doorlock_keycard", 1, {
                lockID = lockData.lockID,
                keyUID = keyUID,
                serialNumber = serial,
                cardType = "master",
                cardName = "Master"
            }) == false) then
                ix.item.Spawn("doorlock_keycard", client, nil, nil, {
                    lockID = lockData.lockID,
                    keyUID = keyUID,
                    serialNumber = serial,
                    cardType = "master",
                    cardName = "Master"
                })
            end
        end
    end

    PLUGIN:SaveData()

    -- finally, consume the item
    inventory:Remove(itemID)

    -- Clean up placement session
    local clientID = client:SteamID64() or tostring(client:EntIndex())
    PLUGIN.placementSessions[clientID] = nil
    
    -- Clear placement flag from item
    local item = ix.item.instances[itemID]
    if (item) then
        item:SetData("placementActive", false)
    end

    if (#doorIDs > 1) then
        client:Notify(string.format("Lock placed on %d door(s).", #doorIDs))
    else
        client:Notify("Lock placed.")
    end
end)

-- Basic door use enforcement stub; detailed interaction and UI are handled in mode/core files.
function PLUGIN:IsDoorLockedByPlugin(door)
    local lock = self:GetDoorLock(door, self.lockTypes.DIGILOCK) or self:GetDoorLock(door, self.lockTypes.DEADLOCK)
    if (not lock) then return false end
    return lock.isLocked, lock
end

function PLUGIN:PlayerUse(client, entity)
    if (not IsValid(entity)) then return end

    if (entity:IsDoor()) then
        local isLocked, lock = self:IsDoorLockedByPlugin(entity)
        if (not lock) then return end

        -- Block door opening if the lock is actually locked
        if (isLocked) then
            return false
        end
    end
end

-- Alternative approach: Hook into keys weapon attack hooks
-- Note: This may not work if Helix handles keys differently
-- The PlayerUse hook above should handle this instead
--[[
hook.Add("WeaponPrimaryAttack", "ixDoorLocks_KeysWeaponLock", function(weapon)
    local client = weapon:GetOwner()
    if (not IsValid(client)) then return end
    
    -- Check if it's the keys weapon (Helix uses "ix_keys" typically)
    local weaponClass = weapon:GetClass()
    -- Debug: print weapon class to help identify the correct name
    -- print("Keys weapon class: " .. tostring(weaponClass))
    if (weaponClass ~= "ix_keys") then return end
    
    local trace = client:GetEyeTrace()
    if (not trace or not trace.Hit) then return end
    
    local door = trace.Entity
    if (not IsValid(door) or not door:IsDoor()) then return end
    
    -- Check if door has a locksystem lock
    local lock = PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DIGILOCK) or PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DEADLOCK)
    if (not lock) then return end -- No locksystem lock, let default behavior handle it
    
    -- Range check
    local doorPos = door:GetPos()
    local clientPos = client:GetPos()
    local distance = doorPos:Distance(clientPos)
    if (distance > 96) then 
        client:Notify("You are too far from the door.")
        return true -- Prevent default behavior
    end
    
    -- Check if door is already locked
    if (lock.isLocked) then
        client:Notify("Door is already locked.")
        return true -- Prevent default behavior
    end
    
    -- Check authorization for locking
    local canLock = false
    local isAdminUser = isAdmin(client)
    
    if (isAdminUser) then
        canLock = true
    elseif (lock.mode == PLUGIN.lockModes.CODE) then
        canLock = true -- Anyone can lock a code lock
    elseif (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
        canLock = PLUGIN:IsBiometricAuthorized(client, lock)
    elseif (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canLock = (highestTier ~= nil)
    end
    
    if (canLock) then
        PLUGIN:SetLockState(lock.lockID, true)
        if (IsValid(door)) then
            door:EmitSound("buttons/button9.wav") -- Lock sound
            client:Notify("Door locked.")
        end
    else
        client:Notify("You are not authorized to lock this.")
    end
    
    return true -- Prevent default keys weapon behavior
end)

hook.Add("WeaponSecondaryAttack", "ixDoorLocks_KeysWeaponUnlock", function(weapon)
    local client = weapon:GetOwner()
    if (not IsValid(client)) then return end
    
    -- Check if it's the keys weapon (check multiple possible class names)
    local weaponClass = weapon:GetClass()
    local isKeysWeapon = (weaponClass == "ix_keys" or weaponClass == "weapon_keys" or weaponClass == "gmod_tool" or string.find(weaponClass:lower(), "key"))
    if (not isKeysWeapon) then return end
    
    local trace = client:GetEyeTrace()
    if (not trace or not trace.Hit) then return end
    
    local door = trace.Entity
    if (not IsValid(door) or not door:IsDoor()) then return end
    
    -- Check if door has a locksystem lock
    local lock = PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DIGILOCK) or PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DEADLOCK)
    if (not lock) then return end -- No locksystem lock, let default behavior handle it
    
    -- Range check
    local doorPos = door:GetPos()
    local clientPos = client:GetPos()
    local distance = doorPos:Distance(clientPos)
    if (distance > 96) then 
        client:Notify("You are too far from the door.")
        return true -- Prevent default behavior
    end
    
    -- Check if door is already unlocked
    if (not lock.isLocked) then
        client:Notify("Door is already unlocked.")
        return true -- Prevent default behavior
    end
    
    -- Check authorization for unlocking
    local canUnlock = false
    local isAdminUser = isAdmin(client)
    
    if (isAdminUser) then
        canUnlock = true
    elseif (lock.mode == PLUGIN.lockModes.CODE) then
        -- For code locks, need manager/master access to unlock via keys
        canUnlock = PLUGIN:HasManagerAccess(client, lock) or PLUGIN:HasMasterAccess(client, lock)
    elseif (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
        canUnlock = PLUGIN:IsBiometricAuthorized(client, lock)
    elseif (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canUnlock = (highestTier ~= nil)
    end
    
    if (canUnlock) then
        PLUGIN:SetLockState(lock.lockID, false)
        if (IsValid(door)) then
            door:EmitSound("buttons/button14.wav") -- Unlock sound
            client:Notify("Door unlocked.")
        end
    else
        client:Notify("You are not authorized to unlock this.")
    end
    
    return true -- Prevent default keys weapon behavior
end)
--]]

-- Hook directly into door Use to intercept keys weapon
-- This is a more direct approach that should work regardless of how Helix handles keys
-- Handle right-click on doors to open lock menu
-- Debounce tables to prevent spam
local quickToggleDebounce = {}
local requestMenuDebounce = {}

-- Quick toggle (single press R)
net.Receive("ixDoorLocks_QuickToggle", function(_, client)
    if (not IsValid(client)) then return end

    -- Debounce to prevent spam
    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local currentTime = CurTime()
    if (quickToggleDebounce[clientID] and (currentTime - quickToggleDebounce[clientID]) < 0.2) then
        return
    end
    quickToggleDebounce[clientID] = currentTime

    local door = net.ReadEntity()
    if (not IsValid(door) or not door:IsDoor()) then 
        client:Notify("You are not looking at a door.")
        return 
    end

    local lock = PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DIGILOCK) or PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DEADLOCK)
    if (not lock) then 
        client:Notify("This door does not have a lock.")
        return 
    end

    -- Range check
    local doorPos = door:GetPos()
    local clientPos = client:GetPos()
    local distance = doorPos:Distance(clientPos)
    if (distance > 96) then 
        client:Notify("You are too far from the door.")
        return 
    end

    -- Check authorization - anyone with access can toggle
    local canToggle = false
    local isAdminUser = isAdmin(client)
    
    if (isAdminUser) then
        canToggle = true
    elseif (lock.mode == PLUGIN.lockModes.CODE) then
        -- For code locks, if locked: need manager/master access. If unlocked: anyone can lock
        if (lock.isLocked) then
            canToggle = PLUGIN:HasManagerAccess(client, lock) or PLUGIN:HasMasterAccess(client, lock)
        else
            canToggle = true -- Anyone can lock an unlocked code lock
        end
    elseif (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
        canToggle = PLUGIN:IsBiometricAuthorized(client, lock)
    elseif (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canToggle = (highestTier ~= nil)
    end

    if (canToggle) then
        PLUGIN:HandleToggleLock(client, lock)
    else
        client:Notify("You do not have access to this lock.")
    end
end)

net.Receive("ixDoorLocks_RequestMenu", function(_, client)
    if (not IsValid(client)) then return end

    -- Debounce to prevent spam
    local clientID = client:SteamID64() or tostring(client:EntIndex())
    local currentTime = CurTime()
    if (requestMenuDebounce[clientID] and (currentTime - requestMenuDebounce[clientID]) < 0.2) then
        return
    end
    requestMenuDebounce[clientID] = currentTime

    local door = net.ReadEntity()
    if (not IsValid(door) or not door:IsDoor()) then return end

    local lock = PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DIGILOCK) or PLUGIN:GetDoorLock(door, PLUGIN.lockTypes.DEADLOCK)
    if (not lock) then return end

    -- Range check for lock interaction
    local doorPos = door:GetPos()
    local clientPos = client:GetPos()
    local distance = doorPos:Distance(clientPos)
    if (distance > 96) then -- 96 units = 6 feet, reasonable interaction range
        return
    end

    -- For keycard locks, check if user has any valid keycard or is admin
    if (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        local isAdminUser = isAdmin(client)
        -- Non-admins need any valid keycard to open the menu (user, manager, or master tier)
        if (not isAdminUser) then
            if (not highestTier) then
                client:Notify("You must hold a valid keycard to access this lock.")
                return
            end
        end
    end

    -- For biometric locks, check if user is inactive
    local isAdminDeactivated = false
    if (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
        local char = client:GetCharacter()
        if (char) then
            local id = char:GetID()
            if (id and lock.biometricInactive and lock.biometricInactive[id]) then
                local isAdminUser = isAdmin(client)
                
                -- Send error message and sound to client
                client:Notify("ERROR: User Deactivated.")
                -- Use net message to play sound on client
                if (IsValid(client)) then
                    net.Start("ixDoorLocks_PlaySound")
                        net.WriteString("buttons/button10.wav")
                    net.Send(client)
                end
                
                if (not isAdminUser) then
                    -- Non-admin: prevent menu from opening
                    return
                else
                    -- Admin is deactivated, but allow menu with limited options (only reactivate button)
                    isAdminDeactivated = true
                end
            end
        end
    end

    -- biometric pairing: if pairing is active and this character is not yet authorized,
    -- using the door will register them and end pairing instead of opening the menu.
    if (lock.mode == PLUGIN.lockModes.BIOMETRIC and lock.pairingActive and lock.pairingUntil and CurTime() < lock.pairingUntil) then
        local char = client:GetCharacter()
        if (char) then
            local id = char:GetID()
            -- Check if already paired
            if (lock.authorizedBiometric[id]) then
                -- Stop pairing process if already paired
                lock.pairingActive = false
                lock.pairingUntil = nil
                lock.pairingMode = nil
                PLUGIN:SaveData()
                client:Notify("You are already paired with this lock. You must be promoted or removed to pair again. Pairing mode has been stopped.")
                return
            end
            
            lock.authorizedBiometric[id] = true
            
            -- If manager pairing, add to managers
            local wasManagerPairing = (lock.pairingMode == "manager")
            if (wasManagerPairing) then
                lock.biometricManagers = lock.biometricManagers or {}
                lock.biometricManagers[id] = true
            end
            
            lock.pairingActive = false
            lock.pairingUntil = nil
            lock.pairingMode = nil

            local doorEnt = PLUGIN:GetDoorFromID(lock.doorID)
            if (IsValid(doorEnt)) then
                doorEnt:EmitSound("buttons/blip1.wav")
            end

            PLUGIN:SaveData()

            local msg = wasManagerPairing and "You have been added as a biometric manager." or "You have been added as a biometric authorized user."
            client:Notify(msg)
            return
        end
    end

    -- Open the lock menu for both digilocks and deadlocks
    local isDeadlock = (lock.type == PLUGIN.lockTypes.DEADLOCK)
    PLUGIN:OpenLockMenu(client, door, lock, isDeadlock, isAdminDeactivated)
end)

-- Authorization helpers ------------------------------------------------------

function PLUGIN:GetCharacterID(client)
    local char = IsValid(client) and client:GetCharacter() or nil
    return char and char:GetID() or nil
end

function PLUGIN:IsInstaller(client, lock)
    if (not lock or not lock.installedByCharID) then return false end
    local id = self:GetCharacterID(client)
    return id == lock.installedByCharID
end

-- Get the highest tier keycard a player has for a lock (for keycard locks only)
-- Returns: "master", "manager", "user", or nil
-- Checks all locks in the same group
function PLUGIN:GetHighestKeycardTier(client, lock)
    if (not lock or lock.mode ~= self.lockModes.KEYCARD) then return nil end
    
    local char = IsValid(client) and client:GetCharacter() or nil
    if (not char) then return nil end
    
    local inventory = char:GetInventory()
    if (not inventory) then return nil end
    
    local highestTier = nil
    local tierPriority = {master = 3, manager = 2, user = 1}
    
    -- Get all locks in the same group (including current lock)
    local groupLocks = self:GetAllGroupLocks(lock)
    
    for _, groupLock in ipairs(groupLocks) do
        for _, item in pairs(inventory:GetItemsByUniqueID("doorlock_keycard") or {}) do
            local lockIDItem = item:GetData("lockID", nil)
            local keyUID = item:GetData("keyUID", nil)
            
            if (lockIDItem == groupLock.lockID and keyUID) then
                for _, cardData in ipairs(groupLock.keycards or {}) do
                    local storedUID = (type(cardData) == "table" and cardData.keyUID) or cardData
                    if (storedUID == keyUID) then
                        if (type(cardData) == "table" and cardData.active) then
                            local cardType = cardData.cardType
                            -- Handle old "installer" type as "master"
                            if (cardType == "installer") then
                                cardType = "master"
                            end
                            
                            local priority = tierPriority[cardType] or 0
                            if (not highestTier or priority > tierPriority[highestTier]) then
                                highestTier = cardType
                            end
                        elseif (type(cardData) == "string") then
                            -- Old format, treat as manager
                            if (not highestTier or tierPriority.manager > tierPriority[highestTier]) then
                                highestTier = "manager"
                            end
                        end
                        break
                    end
                end
            end
        end
    end
    
    return highestTier
end

-- Get the keyUID of the highest tier keycard a player is holding for a lock
-- Returns: keyUID string or nil
function PLUGIN:GetPlayerKeycardUID(client, lock)
    if (not lock or lock.mode ~= self.lockModes.KEYCARD) then return nil end
    
    local char = IsValid(client) and client:GetCharacter() or nil
    if (not char) then return nil end
    
    local inventory = char:GetInventory()
    if (not inventory) then return nil end
    
    local highestTier = nil
    local highestKeyUID = nil
    local tierPriority = {master = 3, manager = 2, user = 1}
    
    for _, item in pairs(inventory:GetItemsByUniqueID("doorlock_keycard") or {}) do
        local lockIDItem = item:GetData("lockID", nil)
        local keyUID = item:GetData("keyUID", nil)
        
        if (lockIDItem == lock.lockID and keyUID) then
            for _, cardData in ipairs(lock.keycards or {}) do
                local storedUID = (type(cardData) == "table" and cardData.keyUID) or cardData
                if (storedUID == keyUID) then
                    if (type(cardData) == "table" and cardData.active) then
                        local cardType = cardData.cardType
                        -- Handle old "installer" type as "master"
                        if (cardType == "installer") then
                            cardType = "master"
                        end
                        
                        local priority = tierPriority[cardType] or 0
                        if (not highestTier or priority > tierPriority[highestTier]) then
                            highestTier = cardType
                            highestKeyUID = keyUID
                        end
                    elseif (type(cardData) == "string") then
                        -- Old format, treat as manager
                        if (not highestTier or tierPriority.manager > tierPriority[highestTier]) then
                            highestTier = "manager"
                            highestKeyUID = keyUID
                        end
                    end
                    break
                end
            end
        end
    end
    
    return highestKeyUID
end

function PLUGIN:IsManager(client, lock)
    local id = self:GetCharacterID(client)
    if (not id or not lock) then return false end

    -- Check all locks in the same group
    local groupLocks = self:GetAllGroupLocks(lock)
    for _, groupLock in ipairs(groupLocks) do
        if (groupLock.authorizedChars and groupLock.authorizedChars[id]) then
            return true
        end
    end

    return false
end

function PLUGIN:IsBiometricAuthorized(client, lock)
    local id = self:GetCharacterID(client)
    if (not id or not lock) then return false end

    -- Check all locks in the same group
    local groupLocks = self:GetAllGroupLocks(lock)
    for _, groupLock in ipairs(groupLocks) do
        if (groupLock.authorizedBiometric and groupLock.authorizedBiometric[id]) then
            -- Check if user is inactive
            if (not groupLock.biometricInactive or not groupLock.biometricInactive[id]) then
                return true
            end
        end
    end

    return false
end

-- Helper function to refresh the keycard list for a client
function PLUGIN:RefreshKeycardList(client, lock)
    if (not IsValid(client) or not lock or lock.mode ~= self.lockModes.KEYCARD) then return end
    
    local char = client:GetCharacter()
    if (not char) then return end

    local inventory = char:GetInventory()
    if (not inventory) then return end

    -- Check highest tier card held
    local highestTier = self:GetHighestKeycardTier(client, lock)
    if (not highestTier or (highestTier ~= "master" and highestTier ~= "manager")) then
        return -- No permission to view
    end

    -- Build keycard list from all locks in the same group (filter story cards for non-admins)
    local cards = {}
    local isAdminViewer = isAdmin(client)
    
    -- Get all locks in the same group (including current lock)
    local groupLocks = self:GetAllGroupLocks(lock)
    
    for _, groupLock in ipairs(groupLocks) do
        for _, cardData in ipairs(groupLock.keycards or {}) do
            if (type(cardData) == "table") then
                -- Filter out story cards if viewer is not admin
                if (not (cardData.storyCardType and not isAdminViewer)) then
                    local cardType = cardData.cardType
                    -- Convert old "installer" type to "master" for display
                    if (cardType == "installer") then
                        cardType = "master"
                    end
                    table.insert(cards, {
                        serialNumber = cardData.serialNumber,
                        keyUID = cardData.keyUID,
                        cardType = cardType,
                        cardName = cardData.cardName or "",
                        active = cardData.active,
                        storyCardType = cardData.storyCardType,
                        lockID = groupLock.lockID, -- Include lockID to show which lock the card belongs to
                        isFromGroup = (groupLock.lockID ~= lock.lockID) -- Mark if from another lock in the group
                    })
                end
            end
        end
    end

    -- Get the keyUID of the card being used
    local userKeyUID = self:GetPlayerKeycardUID(client, lock)
    local door = self:GetDoorFromID(lock.doorID)
    
    net.Start("ixDoorLocks_KeycardView")
        net.WriteString(lock.lockID)
        net.WriteEntity(door) -- Send door entity for Back button
        net.WriteBool(highestTier == "master")
        net.WriteString(userKeyUID or "") -- Pass user's keyUID to prevent self-disable
        net.WriteTable(cards)
    net.Send(client)
end

-- Helper function to refresh the biometric user list for a client
function PLUGIN:RefreshBiometricUserList(client, lock)
    if (not IsValid(client) or not lock or lock.mode ~= self.lockModes.BIOMETRIC) then return end
    
    local isBioManager = self:IsBiometricManager(client, lock)
    local isInstaller = self:IsInstaller(client, lock)
    local isAdminUser = isAdmin(client)
    if (not isBioManager and not isInstaller and not isAdminUser) then
        return -- No permission to view
    end

    local users = {}
    for id, _ in pairs(lock.authorizedBiometric or {}) do
        local char = ix.char.loaded[id]
        -- Only show users who are currently loaded (connected to server)
        if (char) then
            local isInactive = lock.biometricInactive and lock.biometricInactive[id] or false
            -- Master is either the installer OR someone granted master via admin
            local isMaster = (id == lock.installedByCharID) or (lock.masterGranted and lock.masterGranted[id] or false)
            -- If they're a master, they shouldn't be in managers list
            -- Only non-masters can be managers
            local isManager = (not isMaster) and (lock.biometricManagers and lock.biometricManagers[id] or false)
            table.insert(users, {
                id = id,
                name = char:GetName(),
                isManager = isManager,
                isMaster = isMaster, -- Separate flag for master (installer or admin-granted)
                isInactive = isInactive
            })
        end
    end

    local charID = self:GetCharacterID(client)
    local door = self:GetDoorFromID(lock.doorID)
    net.Start("ixDoorLocks_BiometricUserList")
        net.WriteString(lock.lockID)
        net.WriteEntity(door) -- Send door entity for Back button
        net.WriteBool(true) -- All masters can manage other users (but not themselves, handled server-side)
        net.WriteUInt(charID or 0, 32) -- Pass current user ID to prevent self-actions
        net.WriteBool(isAdminUser) -- Pass admin status
        net.WriteTable(users)
    net.Send(client)
end

-- Get all locks in the same group (same mode only, includes current lock)
function PLUGIN:GetAllGroupLocks(lock)
    if (not lock or not lock.groupCode or lock.groupCode == "") then 
        return {lock} -- Return just this lock if no group
    end
    
    local groupLocks = {lock}
    for lockID, otherLock in pairs(self.locks) do
        if (otherLock ~= lock and 
            otherLock.groupCode and otherLock.groupCode ~= "" and
            otherLock.groupCode == lock.groupCode and 
            otherLock.mode == lock.mode) then
            table.insert(groupLocks, otherLock)
        end
    end
    return groupLocks
end

-- Get all other locks in the same group (same mode only, excludes current lock)
function PLUGIN:GetGroupLocks(lock)
    if (not lock or not lock.groupCode or lock.groupCode == "") then 
        return {} -- Return empty if no group
    end
    
    local groupLocks = {}
    for lockID, otherLock in pairs(self.locks) do
        if (otherLock ~= lock and 
            otherLock.groupCode and otherLock.groupCode ~= "" and
            otherLock.groupCode == lock.groupCode and 
            otherLock.mode == lock.mode) then
            table.insert(groupLocks, otherLock)
        end
    end
    return groupLocks
end

-- Check if client has master access (installer or admin-granted)
-- Checks all locks in the same group
function PLUGIN:HasMasterAccess(client, lock)
    if (not lock) then return false end
    
    -- Get all locks in the same group (including current lock)
    local groupLocks = self:GetAllGroupLocks(lock)
    
    for _, groupLock in ipairs(groupLocks) do
        -- Check if installer
        if (self:IsInstaller(client, groupLock)) then
            return true
        end
        
        -- For code locks, check if admin-granted master
        if (groupLock.mode == self.lockModes.CODE) then
            local id = self:GetCharacterID(client)
            if (id and groupLock.masterGranted and groupLock.masterGranted[id]) then
                return true
            end
        end
        
        -- For biometric locks, check if admin-granted master
        if (groupLock.mode == self.lockModes.BIOMETRIC) then
            local id = self:GetCharacterID(client)
            if (id and groupLock.masterGranted and groupLock.masterGranted[id]) then
                return true
            end
        end
    end
    
    return false
end

-- Check if client has manager code access (for code locks)
function PLUGIN:HasManagerAccess(client, lock)
    if (not lock or lock.mode ~= self.lockModes.CODE) then return false end
    return self:IsManager(client, lock)
end

-- Check if client is a biometric manager
-- Checks all locks in the same group
function PLUGIN:IsBiometricManager(client, lock)
    if (not lock or lock.mode ~= self.lockModes.BIOMETRIC) then return false end
    local id = self:GetCharacterID(client)
    if (not id) then return false end
    
    -- Check all locks in the same group
    local groupLocks = self:GetAllGroupLocks(lock)
    for _, groupLock in ipairs(groupLocks) do
        if (groupLock.biometricManagers and groupLock.biometricManagers[id]) then
            return true
        end
    end
    
    return false
end

-- Lock toggle handling.
function PLUGIN:HandleToggleLock(client, lock)
    if (not lock) then return end

    local isLocked = lock.isLocked and true or false
    local isAdminUser = isAdmin(client)

    local door = self:GetDoorFromID(lock.doorID)

    -- locking (from unlocked state)
    if (not isLocked) then
        -- Check authorization for locking
        local canLock = false
        
        if (isAdminUser) then
            canLock = true
        elseif (lock.mode == self.lockModes.CODE) then
            canLock = true -- Anyone can lock a code lock
        elseif (lock.mode == self.lockModes.BIOMETRIC) then
            canLock = self:IsBiometricAuthorized(client, lock)
        elseif (lock.mode == self.lockModes.KEYCARD) then
            local highestTier = self:GetHighestKeycardTier(client, lock)
            canLock = (highestTier ~= nil)
        else
            canLock = self.config.allowAnyoneToLock or self:IsManager(client, lock) or self:IsBiometricAuthorized(client, lock)
        end

        if (not canLock) then
            client:Notify("You are not authorized to lock this.")
            return
        end

        self:SetLockState(lock.lockID, true)
        if (IsValid(door)) then
            door:EmitSound("buttons/button9.wav") -- Lock sound
            client:Notify("Door locked.")
        end

        return
    end

    -- unlocking (admins can always unlock)
    local isAdminUser = isAdmin(client)
    if (isAdminUser) then
        self:SetLockState(lock.lockID, false)
        if (IsValid(door)) then
            door:EmitSound("buttons/button14.wav") -- Unlock sound
            client:Notify("Door unlocked.")
        end
        return
    end

    if (lock.mode == self.lockModes.KEYCARD) then
        local char = client:GetCharacter()
        if (not char) then
            client:Notify("You are not authorized to unlock this.")
            return
        end

        local inventory = char:GetInventory()
        if (not inventory) then
            client:Notify("You are not authorized to unlock this.")
            return
        end

        local hasCard = false
        -- Get all locks in the same group (including current lock)
        local groupLocks = self:GetAllGroupLocks(lock)
        
        for _, item in pairs(inventory:GetItemsByUniqueID("doorlock_keycard") or {}) do
            local itemLockID = item:GetData("lockID", nil)
            local keyUID = item:GetData("keyUID", nil)

            -- Check if this keycard matches any lock in the group
            for _, groupLock in ipairs(groupLocks) do
                if (itemLockID == groupLock.lockID and keyUID) then
                    for _, cardData in ipairs(groupLock.keycards or {}) do
                        local storedUID = (type(cardData) == "table" and cardData.keyUID) or cardData
                        if (storedUID == keyUID) then
                            -- Check if card is active
                            if (type(cardData) == "table" and cardData.active) then
                                hasCard = true
                                break
                            end
                        end
                    end
                end
                if (hasCard) then break end
            end

            if (hasCard) then break end
        end

        if (not hasCard) then
            client:Notify("You do not have a valid active keycard for this lock.")
            return
        end

        self:SetLockState(lock.lockID, false)
        if (IsValid(door)) then
            door:EmitSound("buttons/button14.wav") -- Unlock sound
            client:Notify("Door unlocked.")
        end

        return
    elseif (lock.mode == self.lockModes.BIOMETRIC) then
        if (not self:IsBiometricAuthorized(client, lock)) then
            client:Notify("Access denied.")
            return
        end

        self:SetLockState(lock.lockID, false)
        if (IsValid(door)) then
            door:EmitSound("buttons/button14.wav") -- Unlock sound
            client:Notify("Door unlocked.")
        end

        return
    elseif (lock.mode == self.lockModes.CODE) then
        -- For code locks, only manager code users or masters can toggle directly
        -- User code users must use the code entry UI
        if (not self:HasManagerAccess(client, lock) and not self:HasMasterAccess(client, lock)) then
            client:Notify("You must enter the code to unlock this.")
            return
        end

        self:SetLockState(lock.lockID, false)
        if (IsValid(door)) then
            door:EmitSound("buttons/button14.wav") -- Unlock sound
            client:Notify("Door unlocked.")
        end

        return
    end
end

-- Lock menu handling ---------------------------------------------------------

function PLUGIN:OpenLockMenu(client, door, lock, isDeadlock, isAdminDeactivated)
    if (not IsValid(client) or not lock) then return end

    -- Check if admin is deactivated (if not passed as parameter)
    if (isAdminDeactivated == nil) then
        isAdminDeactivated = false
        if (lock.mode == self.lockModes.BIOMETRIC) then
            local char = client:GetCharacter()
            if (char) then
                local id = char:GetID()
                if (id and lock.biometricInactive and lock.biometricInactive[id] and isAdmin(client)) then
                    isAdminDeactivated = true
                end
            end
        end
    end

    local isManager = self:IsManager(client, lock)
    local isBio = self:IsBiometricAuthorized(client, lock)
    local isBioManager = self:IsBiometricManager(client, lock)
    local hasManager = self:HasManagerAccess(client, lock)
    local hasMaster = self:HasMasterAccess(client, lock)
    -- For keycard locks, check if user has a valid keycard and what tier (based ONLY on keycards held)
    local hasKeycard = false
    local isKeycardMaster = false
    local isKeycardManager = false
    if (lock.mode == self.lockModes.KEYCARD) then
        local highestTier = self:GetHighestKeycardTier(client, lock)
        hasKeycard = (highestTier ~= nil)
        -- Keycard access is based ONLY on keycards held, not installer status
        isKeycardMaster = (highestTier == "master")
        isKeycardManager = (highestTier == "manager" or highestTier == "master")
    end
    local admin = isAdmin(client)

    net.Start("ixDoorLocks_OpenMenu")
        net.WriteEntity(door)
        net.WriteString(lock.lockID or "")
        net.WriteBool(isDeadlock and true or false)
        net.WriteString(lock.type or "")
        net.WriteString(lock.mode or "")
        net.WriteBool(lock.isLocked and true or false)
        net.WriteBool(isManager)
        net.WriteBool(isBio)
        net.WriteBool(isBioManager)
        net.WriteBool(hasManager) -- Manager access (from manager code)
        net.WriteBool(hasMaster) -- Master access (installer/admin)
        net.WriteBool(hasKeycard) -- Has valid keycard for keycard locks
        net.WriteBool(isKeycardMaster) -- Master tier keycard for keycard locks
        net.WriteBool(isKeycardManager) -- Manager or master tier keycard for keycard locks
        net.WriteBool(admin) -- Admin status
        net.WriteBool(isAdminDeactivated) -- Admin is deactivated (limited menu)
    net.Send(client)
end

-- Deadlock entity use entry point.
function PLUGIN:OnDeadlockUsed(client, ent)
    if (not IsValid(client) or not IsValid(ent)) then return end

    local lockID = ent:GetLockID()
    local lock = self:GetLock(lockID)
    if (not lock) then return end

    -- Range check for lock interaction
    local entPos = ent:GetPos()
    local clientPos = client:GetPos()
    local distance = entPos:Distance(clientPos)
    if (distance > 96) then
        return
    end

    -- For biometric locks, check if user is inactive
    local isAdminDeactivated = false
    if (lock.mode == self.lockModes.BIOMETRIC) then
        local char = client:GetCharacter()
        if (char) then
            local id = char:GetID()
            if (id and lock.biometricInactive and lock.biometricInactive[id]) then
                local isAdminUser = isAdmin(client)
                
                -- Send error message and sound to client
                client:Notify("ERROR: User Deactivated.")
                -- Use net message to play sound on client
                if (IsValid(client)) then
                    net.Start("ixDoorLocks_PlaySound")
                        net.WriteString("buttons/button10.wav")
                    net.Send(client)
                end
                
                if (not isAdminUser) then
                    -- Non-admin: prevent menu from opening
                    return
                else
                    -- Admin is deactivated, but allow menu with limited options (only reactivate button)
                    isAdminDeactivated = true
                end
            end
        end
    end

    -- biometric pairing support on the entity as well.
    if (lock.mode == self.lockModes.BIOMETRIC and lock.pairingActive and lock.pairingUntil and CurTime() < lock.pairingUntil) then
        local char = client:GetCharacter()
        if (char) then
            local id = char:GetID()
            -- Check if already paired
            if (lock.authorizedBiometric[id]) then
                -- Stop pairing process if already paired
                lock.pairingActive = false
                lock.pairingUntil = nil
                lock.pairingMode = nil
                PLUGIN:SaveData()
                client:Notify("You are already paired with this lock. You must be promoted or removed to pair again. Pairing mode has been stopped.")
                return
            end
            
            lock.authorizedBiometric[id] = true
            
            -- If manager pairing, add to managers
            local wasManagerPairing = (lock.pairingMode == "manager")
            if (wasManagerPairing) then
                lock.biometricManagers = lock.biometricManagers or {}
                lock.biometricManagers[id] = true
            end
            
            lock.pairingActive = false
            lock.pairingUntil = nil
            lock.pairingMode = nil

            ent:EmitSound("buttons/blip1.wav")

            self:SaveData()

            local msg = wasManagerPairing and "You have been added as a biometric manager." or "You have been added as a biometric authorized user."
            client:Notify(msg)
            return
        end
    end

    local door = self:GetDoorFromID(lock.doorID) or ent.door or ent
    self:OpenLockMenu(client, door, lock, true, isAdminDeactivated)
end

-- Net handling for menu actions and code submission -------------------------

net.Receive("ixDoorLocks_DoAction", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local action = net.ReadString()
    local lockID = net.ReadString()

    local lock = PLUGIN:GetLock(lockID)
    if (not lock) then return end

    if (action == "toggle") then
        PLUGIN:HandleToggleLock(client, lock)

    elseif (action == "remove") then
        -- For keycard locks, master tier keycard holders can remove
        -- For other locks, only Masters (installers/admins) can remove
        local canRemove = false
        if (lock.mode == PLUGIN.lockModes.KEYCARD) then
            local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
            canRemove = (highestTier == "master")
        else
            canRemove = PLUGIN:HasMasterAccess(client, lock)
        end

        if (not canRemove) then
            client:Notify("You are not authorized to remove this lock.")
            return
        end

        local char = client:GetCharacter()
        local charID = char and char:GetID() or nil
        PLUGIN:RemoveLock(lockID, true, charID)
        client:Notify("Lock removed.")

    elseif (action == "admin_remove") then
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to do that.")
            return
        end

        local char = client:GetCharacter()
        local charID = char and char:GetID() or nil
        PLUGIN:RemoveLock(lockID, true, charID)
        client:Notify("Lock removed (admin override).")
    elseif (action == "admin_master_self") then
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to do that.")
            return
        end

        local char = client:GetCharacter()
        if (not char) then return end
        local charID = char:GetID()

        if (lock.mode == PLUGIN.lockModes.CODE) then
            -- Add admin as master code user (authorized with master access)
            lock.authorizedChars = lock.authorizedChars or {}
            lock.authorizedChars[charID] = true
            PLUGIN:SaveData()
            client:Notify("You are now a master on this code lock.")
        elseif (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
            -- Add admin as biometric authorized and mark as master via admin grant
            lock.authorizedBiometric = lock.authorizedBiometric or {}
            lock.authorizedBiometric[charID] = true
            -- Mark as master via admin grant (not as manager)
            lock.masterGranted = lock.masterGranted or {}
            lock.masterGranted[charID] = true
            -- Don't add to biometricManagers - admins are masters, not managers
            PLUGIN:SaveData()
            client:Notify("You are now a master on this biometric lock.")
        end
    elseif (action == "admin_print_master") then
        if (lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end
        
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to do that.")
            return
        end

        local char = client:GetCharacter()
        if (not char) then return end

        local inventory = char:GetInventory()
        if (not inventory) then return end

        -- Admin can print master cards even when door is locked

        lock.keycards = lock.keycards or {}
        lock.nextSerialNumber = lock.nextSerialNumber or 1

        if (#lock.keycards >= PLUGIN.config.maxKeycardsPerLock) then
            client:Notify("This lock already has the maximum number of keycards.")
            return
        end

        local serial = lock.nextSerialNumber
        lock.nextSerialNumber = serial + 1
        local keyUID = tostring(util.CRC(lock.lockID .. os.time() .. math.random() .. serial))

        table.insert(lock.keycards, {
            serialNumber = serial,
            keyUID = keyUID,
            cardType = "master",
            cardName = "Master",
            active = true
        })

        if (inventory:Add("doorlock_keycard", 1, {
            lockID = lock.lockID,
            keyUID = keyUID,
            serialNumber = serial,
            cardType = "master",
            cardName = "Master"
        }) == false) then
            ix.item.Spawn("doorlock_keycard", client, nil, nil, {
                lockID = lock.lockID,
                keyUID = keyUID,
                serialNumber = serial,
                cardType = "master",
                cardName = "Master"
            })
        end

        PLUGIN:SaveData()

        client:Notify("Master keycard printed.")
    elseif (action == "mode_action") then
        if (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
            -- start regular biometric pairing (only managers/installer)
            local isInstaller = PLUGIN:IsInstaller(client, lock)
            local isBioManager = PLUGIN:IsBiometricManager(client, lock)
            
            if (not isInstaller and not isBioManager) then
                client:Notify("Only biometric managers or the installer can start pairing.")
                return
            end

            if (lock.isLocked) then
                client:Notify("Unlock the door before starting pairing.")
                return
            end

            lock.pairingActive = true
            lock.pairingUntil = CurTime() + PLUGIN.config.pairingDuration
            lock.pairingMode = "regular"

            local door = PLUGIN:GetDoorFromID(lock.doorID)
            if (IsValid(door)) then
                door:EmitSound("buttons/button1.wav")
            end

            PLUGIN:SaveData()

            client:Notify("Biometric pairing active. Have another player use the lock.")

        elseif (lock.mode == PLUGIN.lockModes.KEYCARD) then
            -- print a new keycard for keyholders (those with a valid card)
            local char = client:GetCharacter()
            if (not char) then return end

            local inventory = char:GetInventory()
            if (not inventory) then return end

            local hasCard = false
            for _, item in pairs(inventory:GetItemsByUniqueID("doorlock_keycard") or {}) do
                local lockIDItem = item:GetData("lockID", nil)
                local keyUID = item:GetData("keyUID", nil)

                if (lockIDItem == lock.lockID and keyUID) then
                    for _, stored in ipairs(lock.keycards or {}) do
                        local storedUID = (type(stored) == "table" and stored.keyUID) or stored
                        if (storedUID == keyUID) then
                            -- Check if card is active (if it's a table)
                            if (type(stored) == "table" and stored.active) then
                                hasCard = true
                                break
                            elseif (type(stored) == "string") then
                                -- Old format, treat as active
                                hasCard = true
                                break
                            end
                        end
                    end
                end

                if (hasCard) then break end
            end

            if (not hasCard) then
                client:Notify("You must hold a valid keycard for this lock to print a new one.")
                return
            end

            if (lock.isLocked) then
                client:Notify("Unlock the door before printing new keycards.")
                return
            end

            -- Check highest tier card held
            local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
            if (not highestTier or (highestTier ~= "master" and highestTier ~= "manager")) then
                client:Notify("You must hold a master or manager keycard for this lock to print a new one.")
                return
            end

            if (lock.isLocked) then
                client:Notify("Unlock the door before printing new keycards.")
                return
            end

            lock.keycards = lock.keycards or {}
            lock.nextSerialNumber = lock.nextSerialNumber or 1

            if (#lock.keycards >= PLUGIN.config.maxKeycardsPerLock) then
                client:Notify("This lock already has the maximum number of keycards.")
                return
            end

            -- Open UI to select card type and name
            net.Start("ixDoorLocks_KeycardPrintMenu")
                net.WriteString(lockID)
                net.WriteBool(highestTier == "master") -- Can print master cards if holding master card
            net.Send(client)

        end
    elseif (action == "biometric_manager_pairing") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can start manager pairing.")
            return
        end

        if (lock.isLocked) then
            client:Notify("Unlock the door before starting pairing.")
            return
        end

        lock.pairingActive = true
        lock.pairingUntil = CurTime() + PLUGIN.config.pairingDuration
        lock.pairingMode = "manager"

        local door = PLUGIN:GetDoorFromID(lock.doorID)
        if (IsValid(door)) then
            door:EmitSound("buttons/button1.wav")
        end

        PLUGIN:SaveData()

        client:Notify("Manager pairing active. Have another player use the lock.")
-- Helper function to refresh the biometric user list for a client
function PLUGIN:RefreshBiometricUserList(client, lock)
    if (not IsValid(client) or not lock or lock.mode ~= self.lockModes.BIOMETRIC) then return end
    
    local isBioManager = self:IsBiometricManager(client, lock)
    local isInstaller = self:IsInstaller(client, lock)
    local isAdminUser = isAdmin(client)
    if (not isBioManager and not isInstaller and not isAdminUser) then
        return -- No permission to view
    end

    local users = {}
    for id, _ in pairs(lock.authorizedBiometric or {}) do
        local char = ix.char.loaded[id]
        -- Only show users who are currently loaded (connected to server)
        if (char) then
            local isInactive = lock.biometricInactive and lock.biometricInactive[id] or false
            -- Master is either the installer OR someone granted master via admin
            local isMaster = (id == lock.installedByCharID) or (lock.masterGranted and lock.masterGranted[id] or false)
            -- If they're a master, they shouldn't be in managers list
            -- Only non-masters can be managers
            local isManager = (not isMaster) and (lock.biometricManagers and lock.biometricManagers[id] or false)
            table.insert(users, {
                id = id,
                name = char:GetName(),
                isManager = isManager,
                isMaster = isMaster, -- Separate flag for master (installer or admin-granted)
                isInactive = isInactive
            })
        end
    end

    local charID = self:GetCharacterID(client)
    local door = self:GetDoorFromID(lock.doorID)
    net.Start("ixDoorLocks_BiometricUserList")
        net.WriteString(lock.lockID)
        net.WriteEntity(door) -- Send door entity for Back button
        net.WriteBool(true) -- All masters can manage other users (but not themselves, handled server-side)
        net.WriteUInt(charID or 0, 32) -- Pass current user ID to prevent self-actions
        net.WriteBool(isAdminUser) -- Pass admin status
        net.WriteTable(users)
    net.Send(client)
end

    elseif (action == "biometric_view_users") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can view the user list.")
            return
        end

        -- Use the helper function
        PLUGIN:RefreshBiometricUserList(client, lock)
    elseif (action == "biometric_clear_users") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can clear the user list.")
            return
        end

        local charID = PLUGIN:GetCharacterID(client)
        lock.authorizedBiometric = {}
        lock.biometricManagers = {}
        lock.biometricInactive = {} -- Also clear inactive list
        -- Note: masterGranted is intentionally NOT cleared, as admin-granted masters should persist
        
        -- Keep current master (the one clearing) as manager
        if (charID) then
            lock.authorizedBiometric[charID] = true
            lock.biometricManagers[charID] = true
        end

        PLUGIN:SaveData()

        client:Notify("Biometric user list cleared.")
    elseif (action == "biometric_remove_user") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isManager = PLUGIN:IsBiometricManager(client, lock)
        
        if (not isInstaller and not isManager) then
            client:Notify("Only biometric managers or the installer can remove users.")
            return
        end

        local targetID = net.ReadUInt(32)
        if (not targetID) then return end

        -- Prevent removing yourself (unless you're a manager removing yourself)
        local charID = PLUGIN:GetCharacterID(client)
        if (targetID == charID) then
            -- Managers can remove themselves, but masters cannot
            if (isInstaller) then
                client:Notify("Cannot remove yourself from the biometric list.")
                return
            elseif (isManager) then
                -- Managers can remove themselves - allow it
            else
                client:Notify("Cannot remove yourself from the biometric list.")
                return
            end
        end
        
        -- Only masters (installers) or admins can remove managers, managers cannot remove other managers
        local targetIsManager = lock.biometricManagers and lock.biometricManagers[targetID] or false
        local isAdminUser = isAdmin(client)
        if (targetIsManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric masters or admins can remove managers.")
            return
        end

        lock.authorizedBiometric[targetID] = nil
        lock.biometricManagers[targetID] = nil
        -- Also remove from masterGranted if they were an admin-granted master
        if (lock.masterGranted) then
            lock.masterGranted[targetID] = nil
        end
        -- Also remove from biometricInactive if they were deactivated
        if (lock.biometricInactive) then
            lock.biometricInactive[targetID] = nil
        end

        PLUGIN:SaveData()

        client:Notify("User removed from biometric list.")
        
        -- Refresh the user list
        PLUGIN:RefreshBiometricUserList(client, lock)
    elseif (action == "biometric_promote_user") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        
        -- Managers can promote to manager, masters (installers) can promote to manager or master
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can promote users.")
            return
        end

        local targetID = net.ReadUInt(32)
        if (not targetID) then return end

        -- Don't allow promoting yourself (you're already a manager/master)
        local charID = PLUGIN:GetCharacterID(client)
        if (targetID == charID) then
            client:Notify("You are already a manager or master.")
            return
        end

        -- Check if user is authorized
        if (not lock.authorizedBiometric[targetID]) then
            client:Notify("User is not authorized on this lock.")
            return
        end

        -- Check if already a manager
        if (lock.biometricManagers and lock.biometricManagers[targetID]) then
            client:Notify("User is already a manager.")
            return
        end

        -- Promote to manager (not master - only admins/installers can be masters)
        lock.biometricManagers = lock.biometricManagers or {}
        lock.biometricManagers[targetID] = true

        PLUGIN:SaveData()

        client:Notify("User promoted to biometric manager.")
        
        -- Refresh the user list
        PLUGIN:RefreshBiometricUserList(client, lock)
    elseif (action == "biometric_demote_user") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can demote users.")
            return
        end

        local targetID = net.ReadUInt(32)
        if (not targetID) then return end

        -- Prevent demoting yourself
        local charID = PLUGIN:GetCharacterID(client)
        if (targetID == charID) then
            client:Notify("Cannot demote yourself.")
            return
        end

        -- Check if user is authorized
        if (not lock.authorizedBiometric[targetID]) then
            client:Notify("User is not authorized on this lock.")
            return
        end

        -- Check if user is a master
        if (not lock.biometricManagers or not lock.biometricManagers[targetID]) then
            client:Notify("User is not a master.")
            return
        end

        -- Demote from master to regular user
        lock.biometricManagers[targetID] = nil

        PLUGIN:SaveData()

        client:Notify("User demoted from biometric master to regular user.")
        
        -- Refresh the user list
        PLUGIN:RefreshBiometricUserList(client, lock)
    elseif (action == "biometric_toggle_active") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        local isBioManager = PLUGIN:IsBiometricManager(client, lock)
        local isInstaller = PLUGIN:IsInstaller(client, lock)
        local isAdminUser = isAdmin(client)
        
        if (not isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only biometric managers or masters can activate/deactivate users.")
            return
        end

        local targetID = net.ReadUInt(32)
        if (not targetID) then return end

        -- Prevent toggling yourself
        local charID = PLUGIN:GetCharacterID(client)
        if (targetID == charID) then
            client:Notify("Cannot activate/deactivate yourself.")
            return
        end

        -- Check if user is authorized
        if (not lock.authorizedBiometric[targetID]) then
            client:Notify("User is not authorized on this lock.")
            return
        end

        -- Toggle active status
        lock.biometricInactive = lock.biometricInactive or {}
        local isCurrentlyInactive = lock.biometricInactive[targetID] or false
        
        -- Prevent managers from deactivating masters (only masters/admins can deactivate masters)
        -- Allow activation of masters by anyone with permission
        local targetIsMaster = (targetID == lock.installedByCharID)
        if (targetIsMaster and not isCurrentlyInactive and isBioManager and not isInstaller and not isAdminUser) then
            client:Notify("Only masters or admins can deactivate other masters.")
            return
        end

        if (isCurrentlyInactive) then
            lock.biometricInactive[targetID] = nil
            PLUGIN:SaveData()
            client:Notify("User activated.")
        else
            lock.biometricInactive[targetID] = true
            PLUGIN:SaveData()
            client:Notify("User deactivated.")
        end
        
        -- Refresh the user list
        PLUGIN:RefreshBiometricUserList(client, lock)
    elseif (action == "admin_reactivate_user") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to do that.")
            return
        end

        local targetID = net.ReadUInt(32)
        if (not targetID) then return end

        -- Check if user is authorized
        if (not lock.authorizedBiometric[targetID]) then
            client:Notify("User is not authorized on this lock.")
            return
        end

        -- Reactivate the user
        lock.biometricInactive = lock.biometricInactive or {}
        if (lock.biometricInactive[targetID]) then
            lock.biometricInactive[targetID] = nil
            PLUGIN:SaveData()
            client:Notify("User reactivated.")
        else
            client:Notify("User is already active.")
        end
    elseif (action == "admin_reactivate_own_user") then
        if (lock.mode ~= PLUGIN.lockModes.BIOMETRIC) then return end
        
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to do that.")
            return
        end

        local char = client:GetCharacter()
        if (not char) then return end
        local charID = char:GetID()
        if (not charID) then return end

        -- Check if user is authorized
        if (not lock.authorizedBiometric[charID]) then
            client:Notify("You are not authorized on this lock.")
            return
        end

        -- Reactivate the admin's own user
        lock.biometricInactive = lock.biometricInactive or {}
        if (lock.biometricInactive[charID]) then
            lock.biometricInactive[charID] = nil
            PLUGIN:SaveData()
            client:Notify("Your user permissions have been reactivated.")
        else
            client:Notify("Your user permissions are already active.")
        end
    elseif (action == "keycard_view") then
        if (lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end

        local char = client:GetCharacter()
        if (not char) then return end

        local inventory = char:GetInventory()
        if (not inventory) then return end

        -- Check highest tier card held
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        if (not highestTier or (highestTier ~= "master" and highestTier ~= "manager")) then
            client:Notify("You must hold a master or manager keycard to view keycards.")
            return
        end

        -- Build keycard list from all locks in the same group (filter story cards for non-admins)
        local cards = {}
        local isAdminViewer = isAdmin(client)
        
        -- Get all locks in the same group (including current lock)
        local groupLocks = PLUGIN:GetAllGroupLocks(lock)
        
        for _, groupLock in ipairs(groupLocks) do
            for _, cardData in ipairs(groupLock.keycards or {}) do
                if (type(cardData) == "table") then
                    -- Filter out story cards if viewer is not admin
                    if (not (cardData.storyCardType and not isAdminViewer)) then
                        local cardType = cardData.cardType
                        -- Convert old "installer" type to "master" for display
                        if (cardType == "installer") then
                            cardType = "master"
                        end
                        table.insert(cards, {
                            serialNumber = cardData.serialNumber,
                            keyUID = cardData.keyUID,
                            cardType = cardType,
                            cardName = cardData.cardName or "",
                            active = cardData.active,
                            storyCardType = cardData.storyCardType,
                            lockID = groupLock.lockID, -- Include lockID to show which lock the card belongs to
                            isFromGroup = (groupLock.lockID ~= lock.lockID) -- Mark if from another lock in the group
                        })
                    end
                end
            end
        end

        -- Get the keyUID of the card being used
        local userKeyUID = PLUGIN:GetPlayerKeycardUID(client, lock)
        local door = PLUGIN:GetDoorFromID(lock.doorID)
        
        net.Start("ixDoorLocks_KeycardView")
            net.WriteString(lockID)
            net.WriteEntity(door) -- Send door entity for Back button
            net.WriteBool(highestTier == "master")
            net.WriteString(userKeyUID or "") -- Pass user's keyUID to prevent self-disable
            net.WriteTable(cards)
        net.Send(client)
    elseif (action == "keycard_story_menu") then
        if (lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end
        
        if (not isAdmin(client)) then
            client:Notify("You must be an admin to print story cards.")
            return
        end

        if (lock.isLocked) then
            client:Notify("Unlock the door before printing story cards.")
            return
        end

        lock.keycards = lock.keycards or {}
        lock.nextSerialNumber = lock.nextSerialNumber or 1

        if (#lock.keycards >= PLUGIN.config.maxKeycardsPerLock) then
            client:Notify("This lock already has the maximum number of keycards.")
            return
        end

        -- Open story card menu
        net.Start("ixDoorLocks_KeycardStoryMenu")
            net.WriteString(lockID)
        net.Send(client)
    end
end)

-- Group code management handlers --------------------------------------------

net.Receive("ixDoorLocks_SetGroupCode", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()
    local groupCode = net.ReadString()

    local lock = PLUGIN:GetLock(lockID)
    if (not lock) then return end

    -- Only masters can set group codes
    -- For keycard locks, require master tier keycard; for other locks, require master access
    local canManage = false
    if (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canManage = (highestTier == "master")
    else
        canManage = PLUGIN:HasMasterAccess(client, lock)
    end
    
    if (not canManage) then
        client:Notify("You must be a master to set group codes.")
        return
    end

    -- Validate group code (alphanumeric, max 32 chars)
    if (groupCode and groupCode ~= "") then
        if (string.len(groupCode) > 32) then
            client:Notify("Group code must be 32 characters or less.")
            return
        end
        if (not string.match(groupCode, "^[%w_%-]+$")) then
            client:Notify("Group code must be alphanumeric (letters, numbers, underscores, hyphens only).")
            return
        end
    end

    -- Set group code
    lock.groupCode = (groupCode and groupCode ~= "") and groupCode or nil
    PLUGIN:SaveData()

    if (lock.groupCode) then
        client:Notify(string.format("Group code set to: %s", lock.groupCode))
    else
        client:Notify("Group code cleared.")
    end
end)

net.Receive("ixDoorLocks_ClearGroupCode", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()

    local lock = PLUGIN:GetLock(lockID)
    if (not lock) then return end

    -- Only masters can clear group codes
    -- For keycard locks, require master tier keycard; for other locks, require master access
    local canManage = false
    if (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canManage = (highestTier == "master")
    else
        canManage = PLUGIN:HasMasterAccess(client, lock)
    end
    
    if (not canManage) then
        client:Notify("You must be a master to clear group codes.")
        return
    end

    -- Clear group code
    lock.groupCode = nil
    PLUGIN:SaveData()

    client:Notify("Group code cleared.")
end)

net.Receive("ixDoorLocks_ViewGroupLocks", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()

    local lock = PLUGIN:GetLock(lockID)
    if (not lock) then return end

    -- Only masters can view group locks
    -- For keycard locks, require master tier keycard; for other locks, require master access
    local canManage = false
    if (lock.mode == PLUGIN.lockModes.KEYCARD) then
        local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
        canManage = (highestTier == "master")
    else
        canManage = PLUGIN:HasMasterAccess(client, lock)
    end
    
    if (not canManage) then
        client:Notify("You must be a master to view group locks.")
        return
    end

    -- Get all locks in the same group
    local groupLocks = PLUGIN:GetAllGroupLocks(lock)
    
    if (#groupLocks <= 1) then
        client:Notify("This lock is not in a group.")
        return
    end

    -- Build list of lock info
    local lockInfo = {}
    for _, groupLock in ipairs(groupLocks) do
        local door = PLUGIN:GetDoorFromID(groupLock.doorID)
        local doorName = IsValid(door) and door:GetClass() or "Unknown"
        table.insert(lockInfo, string.format("Lock %s (%s) - Door: %s", groupLock.lockID, groupLock.mode, doorName))
    end

    client:Notify(string.format("Group locks (%d total):\n%s", #groupLocks, table.concat(lockInfo, "\n")))
end)

-- Simple admin helpers ------------------------------------------------------

local function findDoorFromTrace(client)
    local data = {}
    data.start = client:GetShootPos()
    data.endpos = data.start + client:GetAimVector() * 96
    data.filter = client

    local trace = util.TraceLine(data)
    local ent = trace.Entity

    if (IsValid(ent) and ent:IsDoor()) then
        return ent
    end
end

ix.command.Add("DoorLockRemove", {
    description = "Remove any Digilock or Deadlock from the door you are looking at. Aim at a door and use this command to remove all locks on it.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local door = findDoorFromTrace(client)
        if (not IsValid(door)) then
            return "You are not looking at a door."
        end

        local removed = 0

        for _, t in ipairs({PLUGIN.lockTypes.DIGILOCK, PLUGIN.lockTypes.DEADLOCK}) do
            local lock = PLUGIN:GetDoorLock(door, t)
            if (lock) then
                PLUGIN:RemoveLock(lock.lockID, true)
                removed = removed + 1
            end
        end

        if (removed == 0) then
            return "No locks found on that door."
        end

        return string.format("Removed %d lock(s).", removed)
    end
})

ix.command.Add("DoorLockList", {
    description = "List all locks on the door you are looking at. Shows lock type, ID, mode, and locked status.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local door = findDoorFromTrace(client)
        if (not IsValid(door)) then
            return "You are not looking at a door."
        end

        local parts = {}

        for _, t in ipairs({PLUGIN.lockTypes.DIGILOCK, PLUGIN.lockTypes.DEADLOCK}) do
            local lock = PLUGIN:GetDoorLock(door, t)
            if (lock) then
                table.insert(parts, string.format("[%s] id=%s mode=%s locked=%s", t, lock.lockID, lock.mode, tostring(lock.isLocked)))
            end
        end

        if (#parts == 0) then
            return "No locks found on that door."
        end

        return table.concat(parts, "\n")
    end
})

ix.command.Add("DoorlockAdminClear", {
    description = "Completely clear all locksystem logic and locking mechanisms from the door you are looking at. Removes all locks, unlocks the door, and cleans up all related data.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local door = findDoorFromTrace(client)
        if (not IsValid(door)) then
            return "You are not looking at a door."
        end

        local doorID = PLUGIN:GetDoorID(door)
        if (not doorID) then
            return "Could not identify door ID."
        end

        local removed = 0
        local locksToRemove = {}

        -- Collect all locks on this door
        for _, t in ipairs({PLUGIN.lockTypes.DIGILOCK, PLUGIN.lockTypes.DEADLOCK}) do
            local lock = PLUGIN:GetDoorLock(door, t)
            if (lock) then
                table.insert(locksToRemove, lock.lockID)
            end
        end

        -- Remove all locks (this will also remove deadlock entities and unlock doors)
        for _, lockID in ipairs(locksToRemove) do
            PLUGIN:RemoveLock(lockID, true) -- unlockDoor = true
            removed = removed + 1
        end

        -- Ensure door is fully unlocked (remove any remaining lock state)
        if (IsValid(door)) then
            door:Fire("Unlock", "", 0)
            door:Fire("Open", "", 0)
            
            -- Also handle door partner if it exists
            local partner = door.GetDoorPartner and door:GetDoorPartner() or nil
            if (IsValid(partner)) then
                partner:Fire("Unlock", "", 0)
                partner:Fire("Open", "", 0)
            end
        end

        -- Clean up door index entry
        if (PLUGIN.doorIndex[doorID]) then
            PLUGIN.doorIndex[doorID] = nil
        end

        -- Save the cleared state
        PLUGIN:SaveData()

        if (removed == 0) then
            return "No locks found on that door. Door cleared of any locksystem logic."
        end

        return string.format("Cleared %d lock(s) and all locksystem logic from the door.", removed)
    end
})

ix.command.Add("DoorLockInfo", {
    description = "Get detailed diagnostic information about the door you are looking at, including entity info, children, and lock status. Useful for troubleshooting door issues.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local door = findDoorFromTrace(client)
        if (not IsValid(door)) then
            return "You are not looking at a door."
        end

        local info = {}
        
        -- Basic entity information
        table.insert(info, "=== DOOR DIAGNOSTIC INFORMATION ===")
        table.insert(info, "")
        table.insert(info, "Entity Class: " .. (door:GetClass() or "N/A"))
        table.insert(info, "Entity Model: " .. (door:GetModel() or "N/A"))
        table.insert(info, "Entity Name: " .. (door:GetName() or "N/A"))
        table.insert(info, "Entity Index: " .. tostring(door:EntIndex()))
        table.insert(info, "Map Creation ID: " .. tostring(door:MapCreationID() or "N/A"))
        
        -- Position and angles
        local pos = door:GetPos()
        local ang = door:GetAngles()
        table.insert(info, "Position: " .. string.format("(%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z))
        table.insert(info, "Angles: " .. string.format("(%.2f, %.2f, %.2f)", ang.p, ang.y, ang.r))
        
        -- Door-specific information
        table.insert(info, "")
        table.insert(info, "=== DOOR PROPERTIES ===")
        table.insert(info, "Is Door: " .. tostring(door:IsDoor()))
        table.insert(info, "Is Locked: " .. tostring(door:IsLocked() or false))
        
        -- Door partner (for double doors)
        local partner = door.GetDoorPartner and door:GetDoorPartner() or nil
        if (IsValid(partner)) then
            table.insert(info, "Has Partner Door: Yes (Index: " .. partner:EntIndex() .. ")")
        else
            table.insert(info, "Has Partner Door: No")
        end
        
        -- Door ID from plugin
        local doorID = PLUGIN:GetDoorID(door)
        table.insert(info, "Plugin Door ID: " .. tostring(doorID or "N/A"))
        
        -- Lock information
        table.insert(info, "")
        table.insert(info, "=== LOCK INFORMATION ===")
        local hasLocks = false
        for _, t in ipairs({PLUGIN.lockTypes.DIGILOCK, PLUGIN.lockTypes.DEADLOCK}) do
            local lock = PLUGIN:GetDoorLock(door, t)
            if (lock) then
                hasLocks = true
                table.insert(info, string.format("[%s] Lock ID: %s", t, lock.lockID))
                table.insert(info, string.format("  Mode: %s", lock.mode or "N/A"))
                table.insert(info, string.format("  Locked: %s", tostring(lock.isLocked)))
                table.insert(info, string.format("  Installed By Char ID: %s", tostring(lock.installedByCharID or "N/A")))
                if (lock.mode == PLUGIN.lockModes.KEYCARD) then
                    table.insert(info, string.format("  Keycards: %d", #(lock.keycards or {})))
                elseif (lock.mode == PLUGIN.lockModes.BIOMETRIC) then
                    local bioCount = 0
                    for _ in pairs(lock.authorizedBiometric or {}) do
                        bioCount = bioCount + 1
                    end
                    table.insert(info, string.format("  Biometric Users: %d", bioCount))
                elseif (lock.mode == PLUGIN.lockModes.CODE) then
                    local authCount = 0
                    for _ in pairs(lock.authorizedChars or {}) do
                        authCount = authCount + 1
                    end
                    table.insert(info, string.format("  Authorized Users: %d", authCount))
                end
            end
        end
        if (not hasLocks) then
            table.insert(info, "No locks found on this door.")
        end
        
        -- Children entities
        table.insert(info, "")
        table.insert(info, "=== CHILDREN ENTITIES ===")
        local children = door:GetChildren()
        if (children and #children > 0) then
            for i, child in ipairs(children) do
                if (IsValid(child)) then
                    table.insert(info, string.format("Child %d: %s (Index: %d, Model: %s)", 
                        i, child:GetClass(), child:EntIndex(), child:GetModel() or "N/A"))
                end
            end
        else
            table.insert(info, "No children entities found.")
        end
        
        -- Additional entity properties
        table.insert(info, "")
        table.insert(info, "=== ADDITIONAL PROPERTIES ===")
        table.insert(info, "Solid Type: " .. tostring(door:GetSolid()))
        table.insert(info, "Collision Group: " .. tostring(door:GetCollisionGroup()))
        table.insert(info, "Move Type: " .. tostring(door:GetMoveType()))
        
        -- Check for custom door properties
        if (door.ixDoorLockID) then
            table.insert(info, "Custom Door ID: " .. tostring(door.ixDoorLockID))
        end
        
        -- Print to server console as well
        print("=== DOOR DIAGNOSTIC INFO (Requested by " .. client:Name() .. ") ===")
        for _, line in ipairs(info) do
            print(line)
        end
        print("==========================================")
        
        return table.concat(info, "\n")
    end
})

ix.command.Add("DoorLockClearPlacement", {
    description = "Clear your active placement session. Use this if you get stuck in a placement session.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local clientID = client:SteamID64() or tostring(client:EntIndex())
        local session = PLUGIN.placementSessions[clientID]
        
        if (not session) then
            return "No active placement session to clear."
        end
        
        local doorCount = #session.doorIDs
        PLUGIN.placementSessions[clientID] = nil
        
        if (doorCount > 0) then
            return string.format("Cleared placement session with %d door(s) selected.", doorCount)
        else
            return "Cleared placement session."
        end
    end
})

net.Receive("ixDoorLocks_SubmitCode", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()
    local op = net.ReadString() -- "unlock", "change_user", "change_master", or "clear_users"
    local code = net.ReadString() or ""

    local lock = PLUGIN:GetLock(lockID)
    if (not lock or lock.mode ~= PLUGIN.lockModes.CODE) then return end

    if (op == "unlock") then
        if (code == "") then return end

        local hash = PLUGIN:HashCode(code)
        local isUserCode = lock.userCodeHash and hash == lock.userCodeHash
        local managerCodeHash = lock.managerCodeHash or lock.masterCodeHash -- Support old masterCodeHash
        local isManagerCode = managerCodeHash and hash == managerCodeHash

        if (isUserCode or isManagerCode) then
            PLUGIN:SetLockState(lockID, false)

            local door = PLUGIN:GetDoorFromID(lock.doorID)
            if (IsValid(door)) then
                door:EmitSound("buttons/button14.wav") -- Unlock sound
            end

            -- Manager code grants manager access (not master)
            if (isManagerCode) then
                local id = PLUGIN:GetCharacterID(client)
                if (id) then
                    lock.authorizedChars = lock.authorizedChars or {}
                    lock.authorizedChars[id] = true
                end
            end

            PLUGIN:SaveData()

            client:Notify("Unlocked.")
        else
            lock.failedAttempts = (lock.failedAttempts or 0) + 1
            PLUGIN:SaveData()

            client:Notify("Incorrect code.")
        end
    elseif (op == "change_user") then
        if (not PLUGIN:HasManagerAccess(client, lock)) then
            client:Notify("Only manager code users can change the user code.")
            return
        end

        if (code == "") then
            client:Notify("Code cannot be empty.")
            return
        end

        lock.userCodeHash = PLUGIN:HashCode(code)
        lock.failedAttempts = 0

        PLUGIN:SaveData()

        client:Notify("User code updated.")
    elseif (op == "change_manager" or op == "change_master") then -- Support old change_master for backwards compatibility
        if (not PLUGIN:HasManagerAccess(client, lock)) then
            client:Notify("Only manager code users can change the manager code.")
            return
        end

        if (code == "") then
            client:Notify("Code cannot be empty.")
            return
        end

        lock.managerCodeHash = PLUGIN:HashCode(code)
        -- Remove old masterCodeHash if it exists
        lock.masterCodeHash = nil
        lock.failedAttempts = 0

        -- Clear user list when manager code is changed
        lock.authorizedChars = {}
        if (lock.installedByCharID) then
            lock.authorizedChars[lock.installedByCharID] = true
        end

        PLUGIN:SaveData()

        client:Notify("Manager code updated. User list cleared.")
    elseif (op == "clear_users") then
        if (not PLUGIN:HasManagerAccess(client, lock)) then
            client:Notify("Only manager code users can clear the user list.")
            return
        end

        lock.authorizedChars = {}
        if (lock.installedByCharID) then
            lock.authorizedChars[lock.installedByCharID] = true
        end

        PLUGIN:SaveData()

        client:Notify("User list cleared.")
    end
end)

-- Keycard print confirmation
net.Receive("ixDoorLocks_KeycardPrintConfirm", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()
    local cardType = net.ReadString() -- "installer", "manager", or "user"
    local cardName = net.ReadString() or ""

    local lock = PLUGIN:GetLock(lockID)
    if (not lock or lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end

    local char = client:GetCharacter()
    if (not char) then return end

    local inventory = char:GetInventory()
    if (not inventory) then return end

    -- Check highest tier card held
    local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
    if (not highestTier or (highestTier ~= "master" and highestTier ~= "manager")) then
        client:Notify("You must hold a master or manager keycard.")
        return
    end

    -- Handle old "installer" type as "master"
    if (cardType == "installer") then
        cardType = "master"
    end

    -- Only master card holders can print master cards
    if (cardType == "master" and highestTier ~= "master") then
        client:Notify("Only master keycard holders can print master keycards.")
        return
    end

    -- Only master or manager card holders can print manager cards
    if (cardType == "manager" and highestTier == "user") then
        client:Notify("You cannot print manager keycards.")
        return
    end

    if (lock.isLocked) then
        client:Notify("Unlock the door before printing new keycards.")
        return
    end

    lock.keycards = lock.keycards or {}
    lock.nextSerialNumber = lock.nextSerialNumber or 1

    if (#lock.keycards >= PLUGIN.config.maxKeycardsPerLock) then
        client:Notify("This lock already has the maximum number of keycards.")
        return
    end

    local serial = lock.nextSerialNumber
    lock.nextSerialNumber = serial + 1
    local keyUID = tostring(util.CRC(lock.lockID .. os.time() .. math.random() .. serial))

    table.insert(lock.keycards, {
        serialNumber = serial,
        keyUID = keyUID,
        cardType = cardType,
        cardName = cardName or "", -- Store as-is, empty string if not provided
        active = true
    })

    if (inventory:Add("doorlock_keycard", 1, {
        lockID = lock.lockID,
        keyUID = keyUID,
        serialNumber = serial,
        cardType = cardType,
        cardName = cardName or "" -- Store as-is, empty string if not provided
    }) == false) then
        ix.item.Spawn("doorlock_keycard", client, nil, nil, {
            lockID = lock.lockID,
            keyUID = keyUID,
            serialNumber = serial,
            cardType = cardType,
            cardName = cardName or "" -- Store as-is, empty string if not provided
        })
    end

    PLUGIN:SaveData()

    client:Notify("New keycard printed.")
end)

-- Keycard management (deactivate/reactivate)
net.Receive("ixDoorLocks_KeycardManage", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()
    local keyUID = net.ReadString()
    local action = net.ReadString() -- "deactivate" or "reactivate"

    local lock = PLUGIN:GetLock(lockID)
    if (not lock or lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end

    -- Check highest tier card held
    local highestTier = PLUGIN:GetHighestKeycardTier(client, lock)
    if (not highestTier) then
        client:Notify("You must hold a valid keycard for this lock.")
        return
    end

    local cardData = nil
    local cardIndex = nil
    local targetLock = nil

    -- Search all locks in the same group for the keycard
    local groupLocks = PLUGIN:GetAllGroupLocks(lock)
    for _, groupLock in ipairs(groupLocks) do
        for i, card in ipairs(groupLock.keycards or {}) do
            local storedUID = (type(card) == "table" and card.keyUID) or card
            if (storedUID == keyUID) then
                cardData = type(card) == "table" and card or {keyUID = card, cardType = "manager", active = true}
                cardIndex = i
                targetLock = groupLock
                break
            end
        end
        if (cardData) then break end
    end

    if (not cardData or not targetLock) then
        client:Notify("Keycard not found.")
        return
    end

    -- Handle old "installer" type as "master"
    local cardType = cardData.cardType
    if (cardType == "installer") then
        cardType = "master"
    end

    if (action == "deactivate") then
        -- Get the keyUID of the card being used to perform the action
        local userKeyUID = PLUGIN:GetPlayerKeycardUID(client, lock)
        
        -- Prevent disabling your own card
        if (userKeyUID == keyUID) then
            client:Notify("Cannot deactivate your own keycard.")
            return
        end
        
        -- Only masters can deactivate other masters or managers
        if (cardType == "master" or cardType == "manager") then
            if (highestTier ~= "master") then
                client:Notify("Only master keycard holders can deactivate master or manager keycards.")
                return
            end
        end

        cardData.active = false
        targetLock.keycards[cardIndex] = cardData
        PLUGIN:SaveData()

        client:Notify("Keycard deactivated.")
        
        -- Refresh the keycard list (use the original lock for the refresh)
        PLUGIN:RefreshKeycardList(client, lock)
    elseif (action == "reactivate") then
        if (highestTier ~= "master") then
            client:Notify("Only master keycard holders can reactivate keycards.")
            return
        end

        cardData.active = true
        targetLock.keycards[cardIndex] = cardData
        PLUGIN:SaveData()

        client:Notify("Keycard reactivated.")
        
        -- Refresh the keycard list (use the original lock for the refresh)
        PLUGIN:RefreshKeycardList(client, lock)
    end
end)

-- Story card print confirmation
net.Receive("ixDoorLocks_KeycardStoryConfirm", function(_, client)
    if (not IsValid(client) or not client:GetCharacter()) then return end

    local lockID = net.ReadString()
    local storyCardType = net.ReadString() -- "air", "earth", "fire", "water", "gold"

    local lock = PLUGIN:GetLock(lockID)
    if (not lock or lock.mode ~= PLUGIN.lockModes.KEYCARD) then return end

    if (not isAdmin(client)) then
        client:Notify("You must be an admin to print story cards.")
        return
    end

    local char = client:GetCharacter()
    if (not char) then return end

    local inventory = char:GetInventory()
    if (not inventory) then return end

    if (lock.isLocked) then
        client:Notify("Unlock the door before printing story cards.")
        return
    end

    lock.keycards = lock.keycards or {}
    lock.nextSerialNumber = lock.nextSerialNumber or 1

    if (#lock.keycards >= PLUGIN.config.maxKeycardsPerLock) then
        client:Notify("This lock already has the maximum number of keycards.")
        return
    end

    -- Story card data
    local storyCards = {
        air = {
            name = "Air Key",
            description = "A special access card with an air motif. A unique circuit is etched onto the card.",
            skin = 0
        },
        earth = {
            name = "Earth Key",
            description = "A special access card with an earth motif. A unique circuit is etched onto the card.",
            skin = 1
        },
        fire = {
            name = "Fire Key",
            description = "A special access card with a fire motif. A unique circuit is etched onto the card.",
            skin = 2
        },
        water = {
            name = "Water Key",
            description = "A special access card with a water motif. A unique circuit is etched onto the card.",
            skin = 3
        },
        gold = {
            name = "Gold Key",
            description = "A special access card with a gold motif. A unique circuit is etched onto the card.",
            skin = 4
        }
    }

    local storyData = storyCards[storyCardType]
    if (not storyData) then
        client:Notify("Invalid story card type.")
        return
    end

    local serial = lock.nextSerialNumber
    lock.nextSerialNumber = serial + 1
    local keyUID = tostring(util.CRC(lock.lockID .. os.time() .. math.random() .. serial))

    table.insert(lock.keycards, {
        serialNumber = serial,
        keyUID = keyUID,
        cardType = "user", -- Story cards are user tier
        cardName = storyData.name,
        storyCardType = storyCardType,
        storyDescription = storyData.description,
        active = true
    })

    if (inventory:Add("doorlock_keycard", 1, {
        lockID = lock.lockID,
        keyUID = keyUID,
        serialNumber = serial,
        cardType = "user",
        cardName = storyData.name,
        storyCardType = storyCardType,
        storyDescription = storyData.description
    }) == false) then
        ix.item.Spawn("doorlock_keycard", client, nil, nil, {
            lockID = lock.lockID,
            keyUID = keyUID,
            serialNumber = serial,
            cardType = "user",
            cardName = storyData.name,
            storyCardType = storyCardType,
            storyDescription = storyData.description
        })
    end

    PLUGIN:SaveData()

    client:Notify("Story card printed: " .. storyData.name)
end)


