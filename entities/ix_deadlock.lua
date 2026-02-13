AddCSLuaFile()

local PLUGIN = PLUGIN

ENT.Type = "anim"
ENT.PrintName = "Deadlock"
ENT.Category = "Helix - Locks"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.PhysgunDisable = true
ENT.bNoPersist = true

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "LockID")

    if (SERVER) then
        self:NetworkVarNotify("LockID", self.OnLockIDChanged)
    end
end

if (SERVER) then
    -- position helper, similar to ix_padlock
    function ENT:GetLockPosition(door, normal)
        local index = door:LookupBone("handle")
        local position = door:GetPos()
        normal = normal or door:GetForward():Angle()

        if (index and index >= 1) then
            position = door:GetBonePosition(index)
        end

        position = position + normal:Forward() * 3.25
        if (door:GetClass() == "prop_door_rotating") then
            position = position + normal:Up() * -2
        end

        normal:RotateAroundAxis(normal:Forward(), 180)
        normal:RotateAroundAxis(normal:Right(), 180)

        return position, normal
    end

    function ENT:SetDoor(door, position, angles)
        if (not IsValid(door) or not door:IsDoor()) then
            return
        end

        local doorPartner = door.GetDoorPartner and door:GetDoorPartner() or nil

        self.door = door
        self.door:DeleteOnRemove(self)
        door.ixDeadlock = self

        if (IsValid(doorPartner)) then
            self.doorPartner = doorPartner
            self.doorPartner:DeleteOnRemove(self)
            doorPartner.ixDeadlock = self
        end

        self:SetPos(position)
        self:SetAngles(angles)
        self:SetParent(door)

        if (PLUGIN and PLUGIN.OnDeadlockTransformChanged) then
            PLUGIN:OnDeadlockTransformChanged(self:GetLockID(), door, position, angles)
        end
    end

    function ENT:Initialize()
        self:SetModel("models/props_wasteland/prison_padlock001a.mdl")
        self:SetSolid(SOLID_VPHYSICS)
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
        self:SetUseType(SIMPLE_USE)

        self.nextUseTime = 0
    end

    function ENT:UpdateTransmitState()
        return TRANSMIT_PVS
    end

    function ENT:OnRemove()
        if (IsValid(self)) then
            self:SetParent(nil)
        end

        if (IsValid(self.door)) then
            self.door.ixDeadlock = nil
        end

        if (IsValid(self.doorPartner)) then
            self.doorPartner.ixDeadlock = nil
        end

        if (not ix.shuttingDown and self.bShouldBreak) then
            local newProp = ents.Create("prop_physics")
            newProp:SetPos(self:GetPos())
            newProp:SetAngles(self:GetAngles())
            newProp:SetModel("models/props_wasteland/prison_padlock001b.mdl")
            newProp:SetSkin(self:GetSkin())
            newProp:Spawn()

            if (math.random() < 0.5) then
                newProp:EmitSound("physics/metal/metal_box_break1.wav")
            else
                newProp:EmitSound("physics/metal/metal_box_break2.wav")
            end

            timer.Simple(15, function()
                if (IsValid(newProp)) then
                    newProp:Remove()
                end
            end)
        end
    end

    function ENT:OnTakeDamage(dmgInfo)
        if (not PLUGIN or not PLUGIN.OnDeadlockDamaged) then return end

        PLUGIN:OnDeadlockDamaged(self:GetLockID(), dmgInfo)
    end

    function ENT:Use(client)
        if (self.nextUseTime > CurTime()) then
            return
        end

        self.nextUseTime = CurTime() + 0.5

        if (PLUGIN and PLUGIN.OnDeadlockUsed) then
            PLUGIN:OnDeadlockUsed(client, self)
        end
    end
else
    ENT.PopulateEntityInfo = true

    function ENT:OnPopulateEntityInfo(tooltip)
        local lockID = self:GetLockID()
        if (not lockID or lockID == "") then return end

        local text = tooltip:AddRow("name")
        text:SetImportant()
        text:SetText("Deadlock")
        text:SizeToContents()
    end

    function ENT:Draw()
        self:DrawModel()
    end
end


