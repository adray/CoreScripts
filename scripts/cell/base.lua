require("enumerations")
require("patterns")
require("utils")

contentFixer = require("contentFixer")
tableHelper = require("tableHelper")
inventoryHelper = require("inventoryHelper")
packetBuilder = require("packetBuilder")

local BaseCell = class("BaseCell")

function BaseCell:__init(cellDescription)

    self.data =
    {
        entry = {
            description = cellDescription
        },
        lastVisit = {},
        objectData = {},
        packets = {
            delete = {},
            place = {},
            spawn = {},
            lock = {},
            trap = {},
            scale = {},
            state = {},
            doorState = {},
            container = {},
            equipment = {},
            ai = {},
            death = {},
            actorList = {},
            position = {},
            statsDynamic = {},
            cellChangeTo = {},
            cellChangeFrom = {}
        }
    }

    self.visitors = {}
    self.authority = nil

    self.isRequestingContainers = false
    self.containerRequestPid = nil

    self.isRequestingActorList = false
    self.actorListRequestPid = nil

    self.unusableContainerUniqueIndexes = {}

    self.isExterior = false

    if string.match(cellDescription, patterns.exteriorCell) then
        self.isExterior = true

        local _, _, gridX, gridY = string.find(cellDescription, patterns.exteriorCell)

        self.gridX = tonumber(gridX)
        self.gridY = tonumber(gridY)
    end
end

function BaseCell:ContainsPosition(posX, posY)

    local cellSize = 8192

    if self.isExterior then
        local correctGridX = math.floor(posX / cellSize)
        local correctGridY = math.floor(posY / cellSize)

        if self.gridX ~= correctGridX or self.gridY ~= correctGridY then
            return false
        end
    end

    return true
end

function BaseCell:HasEntry()
    return self.hasEntry
end

function BaseCell:IsExterior()

    if string.match(self.description, patterns.exteriorCell) then
        return true
    end

    return false
end

function BaseCell:GetVisitorCount()

    local visitorCount = 0
    for visitor in pairs(self.visitors) do visitorCount = visitorCount + 1 end
    return visitorCount
end

function BaseCell:AddVisitor(pid)

    -- Only add new visitor if we don't already have them
    if tableHelper.containsValue(self.visitors, pid) == false then
        table.insert(self.visitors, pid)

        -- Also add a record to the player's list of loaded cells
        Players[pid]:AddCellLoaded(self.description)

        local shouldSendInfo = false
        local lastVisitTimestamp = self.data.lastVisit[Players[pid].accountName]

        -- If this player has never been in this cell, they should be
        -- sent its cell data
        if lastVisitTimestamp == nil then
            shouldSendInfo = true
        -- Otherwise, send them the cell data only if they haven't
        -- visited since last connecting to the server
        elseif Players[pid].initTimestamp > lastVisitTimestamp then
            shouldSendInfo = true
        end

        if shouldSendInfo == true then
            -- First, fix whatever quest problems exist in this cell
            contentFixer.FixCell(pid, self.description)

            self:SendInitialCellData(pid)
        end

        self:SendMomentaryCellData(pid)
    end
end

function BaseCell:RemoveVisitor(pid)

    -- Only remove visitor if they are actually recorded as one
    if tableHelper.containsValue(self.visitors, pid) == true then

        tableHelper.removeValue(self.visitors, pid)

        -- Also remove the record from the player's list of loaded cells
        Players[pid]:RemoveCellLoaded(self.description)

        -- Remember when this visitor left
        self:SaveLastVisit(Players[pid].accountName)

        -- Were we waiting on a container request from this pid?
        if self.isRequestingContainers == true and self.containerRequestPid == pid then
            self.isRequestingContainers = false
            self.containerRequestPid = nil
        end

        -- Were we waiting on an actorList request from this pid?
        if self.isRequestingActorList == true and self.actorListRequestPid == pid then
            self.isRequestingActorList = false
            self.actorListRequestPid = nil
        end
    end
end

function BaseCell:GetAuthority()
    return self.authority
end

function BaseCell:SetAuthority(pid)
    self.authority = pid
    tes3mp.LogMessage(1, "Authority of " .. self.data.entry.description .. " is now player " .. pid)

    self:SendActorAuthority(pid)
end

-- Iterate through saved packets and ensure the object uniqueIndexes they refer to
-- actually exist
function BaseCell:EnsurePacketValidity()

    for packetType, packetArray in pairs(self.data.packets) do
        for arrayIndex, uniqueIndex in pairs(self.data.packets[packetType]) do
            if self.data.objectData[uniqueIndex] == nil then
                tableHelper.removeValue(self.data.packets[packetType], uniqueIndex)
            end
        end
    end
end

-- Check whether an object is in this cell
function BaseCell:ContainsObject(uniqueIndex)
    if self.data.objectData[uniqueIndex] ~= nil and self.data.objectData[uniqueIndex].refId ~= nil then
        return true
    end

    return false
end

function BaseCell:HasContainerData()

    if tableHelper.isEmpty(self.data.packets.container) == true then
        return false
    end

    return true
end

function BaseCell:HasActorData()

    if tableHelper.isEmpty(self.data.packets.actorList) == true then
        return false
    end

    return true
end

function BaseCell:InitializeObjectData(uniqueIndex, refId)

    if uniqueIndex ~= nil and refId ~= nil and self.data.objectData[uniqueIndex] == nil then
        self.data.objectData[uniqueIndex] = {}
        self.data.objectData[uniqueIndex].refId = refId
    end
end

function BaseCell:DeleteObjectData(uniqueIndex)

    if self.data.objectData[uniqueIndex] == nil then
        return
    end

    -- Is this a player's summon? If so, remove it from the summons tracked
    -- for the player
    local summon = self.data.objectData[uniqueIndex].summon

    if summon ~= nil then
        if summon.summonerPlayer ~= nil and logicHandler.IsPlayerNameLoggedIn(summon.summonerPlayer) then
            logicHandler.GetPlayerByName(summon.summonerPlayer).summons[uniqueIndex] = nil
        end
    end

    -- Delete all packets associated with an object
    for packetIndex, packetType in pairs(self.data.packets) do
        tableHelper.removeValue(self.data.packets[packetIndex], uniqueIndex)
    end

    -- Delete all object data
    self.data.objectData[uniqueIndex] = nil
end

function BaseCell:MoveObjectData(uniqueIndex, newCell)

    -- Move all packets about this uniqueIndex from the old cell to the new cell
    for packetIndex, packetType in pairs(self.data.packets) do

        if tableHelper.containsValue(self.data.packets[packetIndex], uniqueIndex) then

            table.insert(newCell.data.packets[packetIndex], uniqueIndex)
            tableHelper.removeValue(self.data.packets[packetIndex], uniqueIndex)
        end
    end

    newCell.data.objectData[uniqueIndex] = self.data.objectData[uniqueIndex]

    self.data.objectData[uniqueIndex] = nil
end

function BaseCell:SaveLastVisit(playerName)
    self.data.lastVisit[playerName] = os.time()
end

-- Iterate through the objects in the ObjectDelete packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectsDeleted(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedDeleteRefIds, refId) or
            tableHelper.containsValue(self.unusableContainerUniqueIndexes, uniqueIndex) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectsDeleted(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can sometimes be deleted clientside without the server's approval and
        -- sometimes not, but we should always send ObjectDelete packets back to the sender
        -- for the sake of the latter situations
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectDelete(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectDelete from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectsDeleted(pid)

    local temporaryLoadedCells = {}

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectDelete from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)
        local refId = tes3mp.GetObjectRefId(i)

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId)

        -- Check whether this object was moved to this cell from another one
        local wasMovedHere = tableHelper.containsValue(self.data.packets.cellChangeFrom, uniqueIndex)

        if wasMovedHere == true then

            local originalCellDescription = self.data.objectData[uniqueIndex].cellChangeFrom

            -- If the new cell is not loaded, load it temporarily
            if LoadedCells[originalCellDescription] == nil then
                logicHandler.LoadCell(originalCellDescription)
                table.insert(temporaryLoadedCells, originalCellDescription)
            end

            local originalCell = LoadedCells[originalCellDescription]

            originalCell:DeleteObjectData(uniqueIndex)
            table.insert(originalCell.data.packets.delete, uniqueIndex)
            originalCell:InitializeObjectData(uniqueIndex, refId)

            self:DeleteObjectData(uniqueIndex)

        else
            -- Check whether this is a placed or spawned object
            local wasPlacedHere = tableHelper.containsValue(self.data.packets.place, uniqueIndex) or
                tableHelper.containsValue(self.data.packets.spawn, uniqueIndex)

            self:DeleteObjectData(uniqueIndex)

            if wasPlacedHere == false then

                table.insert(self.data.packets.delete, uniqueIndex)
                self:InitializeObjectData(uniqueIndex, refId)
            end
        end
    end

    -- Go through every temporary loaded cell and unload it
    for arrayIndex, originalCellDescription in pairs(temporaryLoadedCells) do
        logicHandler.UnloadCell(originalCellDescription)
    end
end

-- Iterate through the objects in the ObjectActivate packet and sync them based
-- on this server's options
function BaseCell:ProcessObjectsActivated(pid)

    tes3mp.ReadReceivedObjectList()

    -- Add your own logic here to prevent object from being activated in certain places,
    -- or to make specific things happen in certain situations, such as when players
    -- are activated by other players
    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local debugMessage = "- "
        local isObjectPlayer = tes3mp.IsObjectPlayer(index)
        local objectPid, objectRefId, objectUniqueIndex

        if isObjectPlayer then
            objectPid = tes3mp.GetObjectPid(index)
            debugMessage = debugMessage .. logicHandler.GetChatName(objectPid)
        else
            objectRefId = tes3mp.GetObjectRefId(index)
            objectUniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)
            debugMessage = debugMessage .. objectRefId .. " " .. objectUniqueIndex
        end

        debugMessage = debugMessage .. " has been activated by "

        local doesObjectHaveActivatingPlayer = tes3mp.DoesObjectHavePlayerActivating(index)
        local activatingPid, activatingRefId, activatingUniqueIndex

        if doesObjectHaveActivatingPlayer then
            activatingPid = tes3mp.GetObjectActivatingPid(index)
            debugMessage = debugMessage .. logicHandler.GetChatName(activatingPid)
        else
            activatingRefId = tes3mp.GetObjectActivatingRefId(index)
            activatingUniqueIndex = tes3mp.GetObjectActivatingRefNum(index) ..
                "-" .. tes3mp.GetObjectActivatingMpNum(index)
            debugMessage = debugMessage .. activatingRefId .. " " .. activatingUniqueIndex
        end

        tes3mp.LogAppend(1, debugMessage)
    end

    tes3mp.CopyReceivedObjectListToStore()
    -- Objects can't be activated clientside without the server's approval, so we send
    -- the packet back to the player who sent it, but we avoid sending it to other
    -- players because OpenMW barely has any code for handling activations not from
    -- the local player
    -- i.e. sendToOtherPlayers is false and skipAttachedPlayer is false
    tes3mp.SendObjectActivate(false, false)
end

-- Iterate through the objects in the ObjectPlace packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectsPlaced(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedCreateRefIds, refId) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectsPlaced(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be placed clientside without the server's approval, so we send
        -- the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectPlace(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectPlace from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectsPlaced(pid)

    local containerUniqueIndexesRequested = {}

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectPlace from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)

        local location = {
            posX = tes3mp.GetObjectPosX(i),
            posY = tes3mp.GetObjectPosY(i),
            posZ = tes3mp.GetObjectPosZ(i),
            rotX = tes3mp.GetObjectRotX(i),
            rotY = tes3mp.GetObjectRotY(i),
            rotZ = tes3mp.GetObjectRotZ(i)
        }

        -- Ensure data integrity before proceeeding
        if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
            self:ContainsPosition(location.posX, location.posY) then

            local refId = tes3mp.GetObjectRefId(i)
            self:InitializeObjectData(uniqueIndex, refId)

            local count = tes3mp.GetObjectCount(i)
            local charge = tes3mp.GetObjectCharge(i)
            local enchantmentCharge = tes3mp.GetObjectEnchantmentCharge(i)
            local goldValue = tes3mp.GetObjectGoldValue(i)

            -- Only save count if it isn't the default value of 1
            if count ~= 1 then
                self.data.objectData[uniqueIndex].count = count
            end

            -- Only save charge if it isn't the default value of -1
            if charge ~= -1 then
                self.data.objectData[uniqueIndex].charge = charge
            end

            -- Only save enchantment charge if it isn't the default value of -1
            if enchantmentCharge ~= -1 then
                self.data.objectData[uniqueIndex].enchantmentCharge = enchantmentCharge
            end

            -- Only save goldValue if it isn't the default value of 1
            if goldValue ~=1 then
                self.data.objectData[uniqueIndex].goldValue = goldValue
            end

            self.data.objectData[uniqueIndex].location = location

            tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId .. ", count: " .. count ..
                ", charge: " .. charge .. ", enchantmentCharge: " .. enchantmentCharge ..
                ", goldValue: " .. goldValue)

            table.insert(self.data.packets.place, uniqueIndex)

            -- Track objects which have containers so we can request their contents
            if tes3mp.DoesObjectHaveContainer(i) then
                table.insert(containerUniqueIndexesRequested, uniqueIndex)
            end
        end
    end

    if tableHelper.isEmpty(containerUniqueIndexesRequested) == false then
        self:RequestContainers(pid, containerUniqueIndexesRequested)
    end
end

-- Iterate through the objects in the ObjectSpawn packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectsSpawned(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedCreateRefIds, refId) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectsSpawned(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be spawned clientside without the server's approval, so we send
        -- the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectSpawn(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectSpawn from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectsSpawned(pid)

    local containerUniqueIndexesRequested = {}

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectSpawn from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)

        local location = {
            posX = tes3mp.GetObjectPosX(i),
            posY = tes3mp.GetObjectPosY(i),
            posZ = tes3mp.GetObjectPosZ(i),
            rotX = tes3mp.GetObjectRotX(i),
            rotY = tes3mp.GetObjectRotY(i),
            rotZ = tes3mp.GetObjectRotZ(i)
        }

        -- Ensure data integrity before proceeeding
        if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
            self:ContainsPosition(location.posX, location.posY) then

            local refId = tes3mp.GetObjectRefId(i)
            self:InitializeObjectData(uniqueIndex, refId)

            tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId)

            self.data.objectData[uniqueIndex].location = location

            if tes3mp.GetObjectSummonState(i) then
                local summonDuration = tes3mp.GetObjectSummonDuration(i)

                if summonDuration > 0 then
                    local summon = {}
                    summon.duration = summonDuration
                    summon.startTime = os.time()

                    local isPlayer = tes3mp.DoesObjectHavePlayerSummoner(i)

                    if isPlayer then
                        local summonerPid = tes3mp.GetObjectSummonerPid(i)
                        tes3mp.LogAppend(1, "- summoned by pid " .. summonerPid)

                        -- Track the player and the summon for each other
                        summon.summonerPlayer = Players[summonerPid].accountName

                        Players[summonerPid].summons[uniqueIndex] = refId
                    else
                        local summonerUniqueIndex = tes3mp.GetObjectSummonerRefNum(i) ..
                            "-" .. tes3mp.GetObjectSummonerMpNum(i)
                        local summonerRefId = tes3mp.GetObjectSummonerRefId(i)
                        tes3mp.LogAppend(1, "- summoned by actor " .. summonerUniqueIndex ..
                            ", refId: " .. summonerRefId)
                    end

                    self.data.objectData[uniqueIndex].summon = summon                
                end
            end

            table.insert(self.data.packets.spawn, uniqueIndex)
            table.insert(self.data.packets.actorList, uniqueIndex)
            table.insert(containerUniqueIndexesRequested, uniqueIndex)
        end
    end

    if tableHelper.isEmpty(containerUniqueIndexesRequested) == false then
        self:RequestContainers(pid, containerUniqueIndexesRequested)
    end
end

-- Iterate through the objects in the ObjectLock packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectsLocked(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedLockRefIds, refId) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectsLocked(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be locked/unlocked clientside without the server's approval,
        -- so we send the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectLock(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectLock from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectsLocked(pid)

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectLock from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)
        local refId = tes3mp.GetObjectRefId(i)
        local lockLevel = tes3mp.GetObjectLockLevel(i)

        self:InitializeObjectData(uniqueIndex, refId)
        self.data.objectData[uniqueIndex].lockLevel = lockLevel

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId .. ", lockLevel: " .. lockLevel)

        tableHelper.insertValueIfMissing(self.data.packets.lock, uniqueIndex)
    end
end

-- Iterate through the objects in the ObjectTrap packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectTrapsTriggered(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedTrapRefIds, refId) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectTrapsTriggered(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be untrapped clientside without the server's approval, so we send
        -- the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectTrap(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectTrap from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectTrapsTriggered(pid)

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectTrap from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)
        local refId = tes3mp.GetObjectRefId(i)

        self:InitializeObjectData(uniqueIndex, refId)

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId)

        tableHelper.insertValueIfMissing(self.data.packets.trap, uniqueIndex)
    end
end

-- Iterate through the objects in the ObjectScaled packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectsScaled(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)
        local scale = tes3mp.GetObjectScale(index)

        if scale >= config.maximumObjectScale then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectsScaled(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be scaled clientside without the server's approval, so we send
        -- the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectScale(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectScale from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectsScaled(pid)

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectScale from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)
        local refId = tes3mp.GetObjectRefId(i)
        local scale = tes3mp.GetObjectScale(i)

        self:InitializeObjectData(uniqueIndex, refId)
        self.data.objectData[uniqueIndex].scale = scale

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId .. ", scale: " .. scale)

        tableHelper.insertValueIfMissing(self.data.packets.scale, uniqueIndex)
    end
end

-- Iterate through the objects in the ObjectState packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessObjectStates(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(config.disallowedStateRefIds, refId) then
            table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
            isValid = false
        end
    end

    if isValid then
        self:SaveObjectStates(pid)

        tes3mp.CopyReceivedObjectListToStore()
        -- Objects can't be enabled or disabled clientside without the server's approval,
        -- so we send the packet to other players and also back to the player who sent it,
        -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
        tes3mp.SendObjectState(true, false)

    else
        tes3mp.LogMessage(1, "Rejected ObjectState from " .. logicHandler.GetChatName(pid) ..
            " about " .. tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveObjectStates(pid)

    if self.data.packets.state == nil then
        self.data.packets.state = {}
    end

    tes3mp.ReadReceivedObjectList()
    tes3mp.LogMessage(1, "Saving ObjectState from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local refNum = tes3mp.GetObjectRefNum(i)
        local mpNum = tes3mp.GetObjectMpNum(i)
        local uniqueIndex = refNum .. "-" .. mpNum
        local refId = tes3mp.GetObjectRefId(i)
        local state = tes3mp.GetObjectState(i)

        self:InitializeObjectData(uniqueIndex, refId)
        self.data.objectData[uniqueIndex].state = state

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId .. ", state: " .. tostring(state))

        tableHelper.insertValueIfMissing(self.data.packets.state, uniqueIndex)
        
        if state == false then
            if Players[pid].stateSpam == nil then
                Players[pid].stateSpam = {}
            end    
            if Players[pid].stateSpam[refId] == nil then
                Players[pid].stateSpam[refId] = 0
            else    
                Players[pid].stateSpam[refId] = Players[pid].stateSpam[refId] + 1
                -- If the player gets 5 false object states for the same refid in that cell, delete it
                if Players[pid].stateSpam[refId] >= 5 then
                    logicHandler.DeleteObjectForPlayer(pid, refId, refNum, mpNum)
                    tes3mp.LogMessage(1, "- " .. uniqueIndex .. " with refId: " .. refId ..
                        " was causing spam and has been deleted")            
                end
            end
        end
    end
end

function BaseCell:SaveDoorStates(pid)

    tes3mp.ReadReceivedObjectList()

    for i = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(i) .. "-" .. tes3mp.GetObjectMpNum(i)
        local refId = tes3mp.GetObjectRefId(i)
        local doorState = tes3mp.GetObjectDoorState(i)

        self:InitializeObjectData(uniqueIndex, refId)
        self.data.objectData[uniqueIndex].doorState = doorState

        tableHelper.insertValueIfMissing(self.data.packets.doorState, uniqueIndex)
    end
end

-- Iterate through the objects in the ObjectDelete packet and only sync and save them
-- if all their refIds are valid
function BaseCell:ProcessContainers(pid)

    local isValid = true
    local rejectedObjects = {}

    tes3mp.ReadReceivedObjectList()

    local subAction = tes3mp.GetObjectListContainerSubAction()

    for index = 0, tes3mp.GetObjectListSize() - 1 do

        local refId = tes3mp.GetObjectRefId(index)
        local uniqueIndex = tes3mp.GetObjectRefNum(index) .. "-" .. tes3mp.GetObjectMpNum(index)

        if tableHelper.containsValue(self.unusableContainerUniqueIndexes, uniqueIndex) then
            
            if subAction == enumerations.containerSub.REPLY_TO_REQUEST then
                tableHelper.removeValue(self.unusableContainerUniqueIndexes, uniqueIndex)
                tes3mp.LogMessage(1, "Making container " .. uniqueIndex .. " usable as a result of request reply")
            else
                table.insert(rejectedObjects, refId .. " " .. uniqueIndex)
                isValid = false

                Players[pid]:Message("That container is currently unusable for synchronization reasons.\n")
            end
        end
    end

    if isValid then
        self:SaveContainers(pid)
    else
        tes3mp.LogMessage(1, "Rejected Container from " .. logicHandler.GetChatName(pid) .." about " ..
            tableHelper.concatenateArrayValues(rejectedObjects, 1, ", "))
    end
end

function BaseCell:SaveContainers(pid)

    tes3mp.ReadReceivedObjectList()
    tes3mp.CopyReceivedObjectListToStore()

    tes3mp.LogMessage(1, "Saving Container from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    local action = tes3mp.GetObjectListAction()
    local subAction = tes3mp.GetObjectListContainerSubAction()

    for objectIndex = 0, tes3mp.GetObjectListSize() - 1 do

        local uniqueIndex = tes3mp.GetObjectRefNum(objectIndex) .. "-" .. tes3mp.GetObjectMpNum(objectIndex)
        local refId = tes3mp.GetObjectRefId(objectIndex)

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId)

        self:InitializeObjectData(uniqueIndex, refId)

        tableHelper.insertValueIfMissing(self.data.packets.container, uniqueIndex)

        local inventory = self.data.objectData[uniqueIndex].inventory

        -- If this object's inventory is nil, or if the action is SET,
        -- change the inventory to an empty table
        if inventory == nil or action == enumerations.container.SET then
            inventory = {}
        end

        for itemIndex = 0, tes3mp.GetContainerChangesSize(objectIndex) - 1 do

            local itemRefId = tes3mp.GetContainerItemRefId(objectIndex, itemIndex)
            local itemCount = tes3mp.GetContainerItemCount(objectIndex, itemIndex)
            local itemCharge = tes3mp.GetContainerItemCharge(objectIndex, itemIndex)
            local itemEnchantmentCharge = tes3mp.GetContainerItemEnchantmentCharge(objectIndex, itemIndex)

            -- Check if the object's stored inventory contains this item already
            if inventoryHelper.containsItem(inventory, itemRefId, itemCharge) then
                local foundIndex = inventoryHelper.getItemIndex(inventory, itemRefId, itemCharge)
                local item = inventory[foundIndex]

                if action == enumerations.container.ADD then
                    item.count = item.count + itemCount

                elseif action == enumerations.container.REMOVE then
                    local actionCount = tes3mp.GetContainerItemActionCount(objectIndex, itemIndex)
                    local newCount = item.count - actionCount

                    -- The item will still exist in the container with a lower count
                    if newCount > 0 then
                        item.count = newCount
                    -- The item is to be completely removed
                    elseif newCount == 0 then
                        inventory[foundIndex] = nil
                    else
                        actionCount = item.count
                        tes3mp.LogAppend(2, "- Attempt to remove more than possible from item")
                        tes3mp.LogAppend(2, "- Removed just " .. actionCount .. " instead")
                        tes3mp.SetContainerItemActionCountByIndex(objectIndex, itemIndex, actionCount)
                        inventory[foundIndex] = nil
                    end
                end
            else
                if action == enumerations.container.REMOVE then
                    tes3mp.LogAppend(2, "- Attempt to remove non-existent item")
                    tes3mp.SetContainerItemActionCountByIndex(objectIndex, itemIndex, 0)
                else
                    inventoryHelper.addItem(inventory, itemRefId, itemCount,
                        itemCharge, itemEnchantmentCharge)
                end
            end
        end

        tableHelper.cleanNils(inventory)
        self.data.objectData[uniqueIndex].inventory = inventory
    end

    -- Is this a player replying to our request for container contents?
    -- If so, only send the reply to other visitors
    -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is true
    if subAction == enumerations.containerSub.REPLY_TO_REQUEST then
        tes3mp.SendContainer(true, true)
    -- Otherwise, send the received packet to everyone, including the
    -- player who sent it (because no clientside changes will be made
    -- to the container they're in otherwise)
    -- i.e. sendToOtherPlayers is true and skipAttachedPlayer is false
    else
        tes3mp.SendContainer(true, false)
    end

    self:Save()

    if action == enumerations.container.SET then
        self.isRequestingContainers = false
    end
end

function BaseCell:SaveActorList(pid)

    tes3mp.ReadReceivedActorList()
    tes3mp.LogMessage(1, "Saving ActorList from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for actorIndex = 0, tes3mp.GetActorListSize() - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(actorIndex) .. "-" .. tes3mp.GetActorMpNum(actorIndex)
        local refId = tes3mp.GetActorRefId(actorIndex)

        self:InitializeObjectData(uniqueIndex, refId)
        tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", refId: " .. refId)

        tableHelper.insertValueIfMissing(self.data.packets.actorList, uniqueIndex)
    end

    self:Save()

    self.isRequestingActorList = false
end

function BaseCell:SaveActorPositions()

    tes3mp.ReadCellActorList(self.description)
    local actorListSize = tes3mp.GetActorListSize()

    if actorListSize == 0 then
        return
    end

    for i = 0, actorListSize - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(i) .. "-" .. tes3mp.GetActorMpNum(i)

        if tes3mp.DoesActorHavePosition(i) == true and self:ContainsObject(uniqueIndex) then

            self.data.objectData[uniqueIndex].location = {
                posX = tes3mp.GetActorPosX(i),
                posY = tes3mp.GetActorPosY(i),
                posZ = tes3mp.GetActorPosZ(i),
                rotX = tes3mp.GetActorRotX(i),
                rotY = tes3mp.GetActorRotY(i),
                rotZ = tes3mp.GetActorRotZ(i)
            }

            tableHelper.insertValueIfMissing(self.data.packets.position, uniqueIndex)
        end
    end
end

function BaseCell:SaveActorStatsDynamic()

    tes3mp.ReadCellActorList(self.description)
    local actorListSize = tes3mp.GetActorListSize()

    if actorListSize == 0 then
        return
    end

    for i = 0, actorListSize - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(i) .. "-" .. tes3mp.GetActorMpNum(i)

        if tes3mp.DoesActorHaveStatsDynamic(i) == true and self:ContainsObject(uniqueIndex) then

            self.data.objectData[uniqueIndex].stats = {
                healthBase = tes3mp.GetActorHealthBase(i),
                healthCurrent = tes3mp.GetActorHealthCurrent(i),
                healthModified = tes3mp.GetActorHealthModified(i),
                magickaBase = tes3mp.GetActorMagickaBase(i),
                magickaCurrent = tes3mp.GetActorMagickaCurrent(i),
                magickaModified = tes3mp.GetActorMagickaModified(i),
                fatigueBase = tes3mp.GetActorFatigueBase(i),
                fatigueCurrent = tes3mp.GetActorFatigueCurrent(i),
                fatigueModified = tes3mp.GetActorFatigueModified(i)
            }

            tableHelper.insertValueIfMissing(self.data.packets.statsDynamic, uniqueIndex)
        end
    end
end

function BaseCell:SaveActorEquipment(pid)

    tes3mp.ReadReceivedActorList()
    tes3mp.LogMessage(1, "Saving ActorEquipment from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    local actorListSize = tes3mp.GetActorListSize()

    if actorListSize == 0 then
        return
    end

    for actorIndex = 0, actorListSize - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(actorIndex) .. "-" .. tes3mp.GetActorMpNum(actorIndex)
        tes3mp.LogAppend(1, "- " .. uniqueIndex)

        if self:ContainsObject(uniqueIndex) then
            self.data.objectData[uniqueIndex].equipment = {}

            for itemIndex = 0, tes3mp.GetEquipmentSize() - 1 do

                local itemRefId = tes3mp.GetActorEquipmentItemRefId(actorIndex, itemIndex)

                if itemRefId ~= "" then

                    self.data.objectData[uniqueIndex].equipment[itemIndex] = {
                        refId = itemRefId,
                        count = tes3mp.GetActorEquipmentItemCount(actorIndex, itemIndex),
                        charge = tes3mp.GetActorEquipmentItemCharge(actorIndex, itemIndex),
                        enchantmentCharge = tes3mp.GetActorEquipmentItemEnchantmentCharge(actorIndex, itemIndex)
                    }
                end
            end

            tableHelper.insertValueIfMissing(self.data.packets.equipment, uniqueIndex)
        end
    end

    self:Save()
end

-- Iterate through the actors in the ActorAI packet and only sync and save them
-- based on this server's options
function BaseCell:ProcessActorAI(pid)

    tes3mp.ReadReceivedActorList()
    tes3mp.CopyReceivedActorListToStore()
    -- Actor AI packages are currently enabled unilaterally on the client
    -- that has sent them, so we only need to send them to other players,
    -- and can skip the original sender
    -- i.e. sendToOtherVisitors is true and skipAttachedPlayer is true
    tes3mp.SendActorAI(true, true)
end

function BaseCell:SaveActorDeath(pid)

    if self.data.packets.death == nil then
        self.data.packets.death = {}
    end

    local containerUniqueIndexesRequested = {}

    tes3mp.ReadReceivedActorList()
    tes3mp.LogMessage(1, "Saving ActorDeath from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    local actorListSize = tes3mp.GetActorListSize()

    if actorListSize == 0 then
        return
    end

    for actorIndex = 0, actorListSize - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(actorIndex) .. "-" .. tes3mp.GetActorMpNum(actorIndex)

        if self:ContainsObject(uniqueIndex) then

            local deathReason = "committed suicide"

            if tes3mp.DoesActorHavePlayerKiller(actorIndex) then
                local killerPid = tes3mp.GetActorKillerPid(actorIndex)
                deathReason = "was killed by player " .. logicHandler.GetChatName(killerPid)

                self.data.objectData[uniqueIndex].killer = {
                    player = Players[killerPid].accountName
                }
            else
                local killerName = tes3mp.GetActorKillerName(actorIndex)
                local killerUniqueIndex = tes3mp.GetActorKillerRefNum(actorIndex) ..
                    "-" .. tes3mp.GetActorKillerMpNum(actorIndex)

                if killerName ~= "" and uniqueIndex ~= killerUniqueIndex then
                    deathReason = "was killed by " .. killerName

                    self.data.objectData[uniqueIndex].killer = {
                        refId = tes3mp.GetActorKillerRefId(actorIndex),
                        uniqueIndex = killerUniqueIndex
                    }
                end
            end

            tes3mp.LogAppend(1, "- " .. uniqueIndex .. ", deathReason: " .. deathReason)

            tableHelper.insertValueIfMissing(self.data.packets.death, uniqueIndex)

            -- Prevent this actor's container from being used until we update
            -- its contents based on a request to a player
            --
            -- This is an unfortunate workaround that needs to be used until
            -- some changes are made on the C++ side
            table.insert(self.unusableContainerUniqueIndexes, uniqueIndex)
            table.insert(containerUniqueIndexesRequested, uniqueIndex)
        end
    end

    if tableHelper.isEmpty(containerUniqueIndexesRequested) == false then
        self:RequestContainers(pid, containerUniqueIndexesRequested)
    end

    self:Save()
end

function BaseCell:SaveActorCellChanges(pid)

    local temporaryLoadedCells = {}

    tes3mp.ReadReceivedActorList()
    tes3mp.LogMessage(1, "Saving ActorCellChange from " .. logicHandler.GetChatName(pid) ..
        " about " .. self.description)

    for actorIndex = 0, tes3mp.GetActorListSize() - 1 do

        local uniqueIndex = tes3mp.GetActorRefNum(actorIndex) .. "-" .. tes3mp.GetActorMpNum(actorIndex)
        local newCellDescription = tes3mp.GetActorCell(actorIndex)

        tes3mp.LogAppend(1, "- " .. uniqueIndex .. " moved to " .. newCellDescription)

        -- If the new cell is not loaded, load it temporarily
        if LoadedCells[newCellDescription] == nil then
            logicHandler.LoadCell(newCellDescription)
            table.insert(temporaryLoadedCells, newCellDescription)
        end

        local newCell = LoadedCells[newCellDescription]

        -- Only proceed if this Actor is actually supposed to exist in this cell
        if self.data.objectData[uniqueIndex] ~= nil then

            -- Was this actor spawned in the old cell, instead of being a pre-existing actor?
            -- If so, delete it entirely from the old cell and make it get spawned in the new cell
            if tableHelper.containsValue(self.data.packets.spawn, uniqueIndex) == true then
                tes3mp.LogAppend(1, "-- As a server-only object, it was moved entirely")
                self:MoveObjectData(uniqueIndex, newCell)

            -- Was this actor moved to the old cell from another cell?
            elseif tableHelper.containsValue(self.data.packets.cellChangeFrom, uniqueIndex) == true then

                local originalCellDescription = self.data.objectData[uniqueIndex].cellChangeFrom

                -- Is the new cell actually this actor's original cell?
                -- If so, move its data back and remove all of its cell change data
                if originalCellDescription == newCellDescription then
                    tes3mp.LogAppend(1, "-- It is now back in its original cell " .. originalCellDescription)
                    self:MoveObjectData(uniqueIndex, newCell)

                    tableHelper.removeValue(newCell.data.packets.cellChangeTo, uniqueIndex)
                    tableHelper.removeValue(newCell.data.packets.cellChangeFrom, uniqueIndex)

                    newCell.data.objectData[uniqueIndex].cellChangeTo = nil
                    newCell.data.objectData[uniqueIndex].cellChangeFrom = nil
                -- Otherwise, move its data to the new cell, delete it from the old cell, and update its
                -- information in its original cell
                else
                    self:MoveObjectData(uniqueIndex, newCell)

                    -- If the original cell is not loaded, load it temporarily
                    if LoadedCells[originalCellDescription] == nil then
                        logicHandler.LoadCell(originalCellDescription)
                        table.insert(temporaryLoadedCells, originalCellDescription)
                    end

                    local originalCell = LoadedCells[originalCellDescription]

                    if originalCell.data.objectData[uniqueIndex] ~= nil then
                        tes3mp.LogAppend(1, "-- This is now referenced in its original cell " .. originalCellDescription)
                        originalCell.data.objectData[uniqueIndex].cellChangeTo = newCellDescription
                    else
                        tes3mp.LogAppend(3, "-- It does not exist in its original cell " .. originalCellDescription ..
                            "! Please report this to a developer")
                    end
                end

            -- Otherwise, simply move this actor's data to the new cell and mark it as being moved there
            -- in its old cell, as long as it's not supposed to already be in the new cell
            elseif self.data.objectData[uniqueIndex].cellChangeTo ~= newCellDescription then

                tes3mp.LogAppend(1, "-- This was its first move away from its original cell")

                self:MoveObjectData(uniqueIndex, newCell)

                table.insert(self.data.packets.cellChangeTo, uniqueIndex)

                if self.data.objectData[uniqueIndex] == nil then
                    self.data.objectData[uniqueIndex] = {}
                end

                self.data.objectData[uniqueIndex].cellChangeTo = newCellDescription

                table.insert(newCell.data.packets.cellChangeFrom, uniqueIndex)

                newCell.data.objectData[uniqueIndex].cellChangeFrom = self.description
            end

            if newCell.data.objectData[uniqueIndex] ~= nil then
                newCell.data.objectData[uniqueIndex].location = {
                    posX = tes3mp.GetActorPosX(actorIndex),
                    posY = tes3mp.GetActorPosY(actorIndex),
                    posZ = tes3mp.GetActorPosZ(actorIndex),
                    rotX = tes3mp.GetActorRotX(actorIndex),
                    rotY = tes3mp.GetActorRotY(actorIndex),
                    rotZ = tes3mp.GetActorRotZ(actorIndex)
                }
            end
        else
            tes3mp.LogAppend(3, "-- Invalid or repeated cell change was attempted! Please report this to a developer")
        end
    end

    -- Go through every temporary loaded cell and unload it
    for arrayIndex, newCellDescription in pairs(temporaryLoadedCells) do
        logicHandler.UnloadCell(newCellDescription)
    end

    self:Save()
end

function BaseCell:SendObjectsDeleted(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    -- Objects deleted
    for arrayIndex, uniqueIndex in pairs(self.data.packets.delete) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetObjectRefNum(splitIndex[1])
        tes3mp.SetObjectMpNum(splitIndex[2])
        tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)
        tes3mp.AddObject()

        objectCount = objectCount + 1
    end

    if objectCount > 0 then
        tes3mp.SendObjectDelete()
    end
end

function BaseCell:SendObjectsPlaced(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.place) do

        local location = self.data.objectData[uniqueIndex].location

        -- Ensure data integrity before proceeeding
        if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
            self:ContainsPosition(location.posX, location.posY) then

            local splitIndex = uniqueIndex:split("-")
            tes3mp.SetObjectRefNum(splitIndex[1])
            tes3mp.SetObjectMpNum(splitIndex[2])
            tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)

            local count = self.data.objectData[uniqueIndex].count
            local charge = self.data.objectData[uniqueIndex].charge
            local enchantmentCharge = self.data.objectData[uniqueIndex].enchantmentCharge
            local goldValue = self.data.objectData[uniqueIndex].goldValue

            -- Use default count of 1 when the value is missing
            if count == nil then
                count = 1
            end

            -- Use default charge of -1 when the value is missing
            if charge == nil then
                charge = -1
            end

            -- Use default enchantment charge of -1 when the value is missing
            if enchantmentCharge == nil then
                enchantmentCharge = -1
            end

            -- Use default goldValue of 1 when the value is missing
            if goldValue == nil then
                goldValue = 1
            end

            tes3mp.SetObjectCount(count)
            tes3mp.SetObjectCharge(charge)
            tes3mp.SetObjectEnchantmentCharge(enchantmentCharge)
            tes3mp.SetObjectGoldValue(goldValue)
            tes3mp.SetObjectPosition(location.posX, location.posY, location.posZ)
            tes3mp.SetObjectRotation(location.rotX, location.rotY, location.rotZ)

            tes3mp.AddObject()

            objectCount = objectCount + 1
        else
            self.data.objectData[uniqueIndex] = nil
            tableHelper.removeValue(self.data.packets.place, uniqueIndex)
        end
    end

    if objectCount > 0 then
        tes3mp.SendObjectPlace()
    end
end

function BaseCell:SendObjectsSpawned(pid)

    -- Keep this around for backwards compatibility
    if self.data.packets.spawn == nil then
        self.data.packets.spawn = {}
    end

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.spawn) do

        local location = self.data.objectData[uniqueIndex].location

        -- Ensure data integrity before proceeeding
        if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
            self:ContainsPosition(location.posX, location.posY) then

            local shouldSkip = false
            local summon = self.data.objectData[uniqueIndex].summon

            if summon ~= nil then
                local currentTime = os.time()
                local finishTime = summon.startTime + summon.duration

                if currentTime >= finishTime then
                    self:DeleteObjectData(uniqueIndex)
                    shouldSkip = true
                else
                    local remainingTime = finishTime - currentTime
                    tes3mp.SetObjectSummonDuration(remainingTime)
                end
            end

            if shouldSkip == false then

                local splitIndex = uniqueIndex:split("-")
                tes3mp.SetObjectRefNum(splitIndex[1])
                tes3mp.SetObjectMpNum(splitIndex[2])
                tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)

                tes3mp.SetObjectPosition(location.posX, location.posY, location.posZ)
                tes3mp.SetObjectRotation(location.rotX, location.rotY, location.rotZ)

                tes3mp.AddObject()

                objectCount = objectCount + 1
            end
        else
            self.data.objectData[uniqueIndex] = nil
            tableHelper.removeValue(self.data.packets.spawn, uniqueIndex)
        end
    end

    if objectCount > 0 then
        tes3mp.SendObjectSpawn()
    end
end

function BaseCell:SendObjectsLocked(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.lock) do

        local refId = self.data.objectData[uniqueIndex].refId
        local lockLevel = self.data.objectData[uniqueIndex].lockLevel

        if refId ~= nil and lockLevel ~= nil then

            local splitIndex = uniqueIndex:split("-")
            tes3mp.SetObjectRefNum(splitIndex[1])
            tes3mp.SetObjectMpNum(splitIndex[2])
            tes3mp.SetObjectRefId(refId)
            tes3mp.SetObjectLockLevel(lockLevel)
            tes3mp.AddObject()

            objectCount = objectCount + 1
        else
            tableHelper.removeValue(self.data.packets.lock, uniqueIndex)
        end
    end

    if objectCount > 0 then
        tes3mp.SendObjectLock()
    end
end

function BaseCell:SendObjectTrapsTriggered(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.trap) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetObjectRefNum(splitIndex[1])
        tes3mp.SetObjectMpNum(splitIndex[2])
        tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)
        tes3mp.SetObjectDisarmState(true)
        tes3mp.AddObject()

        objectCount = objectCount + 1
    end

    if objectCount > 0 then
        tes3mp.SendObjectTrap()
    end
end

function BaseCell:SendObjectsScaled(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.scale) do

        local splitIndex = uniqueIndex:split("-")
        local refId = self.data.objectData[uniqueIndex].refId
        local scale = self.data.objectData[uniqueIndex].scale

        if refId ~= nil and scale ~= nil then

            tes3mp.SetObjectRefNum(splitIndex[1])
            tes3mp.SetObjectMpNum(splitIndex[2])
            tes3mp.SetObjectRefId(refId)
            tes3mp.SetObjectScale(scale)
            tes3mp.AddObject()

            objectCount = objectCount + 1
        end
    end

    if objectCount > 0 then
        tes3mp.SendObjectScale()
    end
end

function BaseCell:SendObjectStates(pid)

    if self.data.packets.state == nil then
        self.data.packets.state = {}
    end

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.state) do

        local splitIndex = uniqueIndex:split("-")
        local refId = self.data.objectData[uniqueIndex].refId
        local state = self.data.objectData[uniqueIndex].state

        if refId ~= nil and state ~= nil then

            tes3mp.SetObjectRefNum(splitIndex[1])
            tes3mp.SetObjectMpNum(splitIndex[2])
            tes3mp.SetObjectRefId(refId)
            tes3mp.SetObjectState(state)
            tes3mp.AddObject()

            objectCount = objectCount + 1
        end
    end

    if objectCount > 0 then
        tes3mp.SendObjectState()
    end
end

function BaseCell:SendDoorStates(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.doorState) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetObjectRefNum(splitIndex[1])
        tes3mp.SetObjectMpNum(splitIndex[2])
        tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)
        tes3mp.SetObjectDoorState(self.data.objectData[uniqueIndex].doorState)
        tes3mp.AddObject()

        objectCount = objectCount + 1
    end

    if objectCount > 0 then
        tes3mp.SendDoorState()
    end
end

function BaseCell:SendContainers(pid)

    local objectCount = 0

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.container) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetObjectRefNum(splitIndex[1])
        tes3mp.SetObjectMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) and self.data.objectData[uniqueIndex].inventory ~= nil then
            tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)

            for itemIndex, item in pairs(self.data.objectData[uniqueIndex].inventory) do
                tes3mp.SetContainerItemRefId(item.refId)
                tes3mp.SetContainerItemCount(item.count)
                tes3mp.SetContainerItemCharge(item.charge)

                if item.enchantmentCharge == nil then
                    item.enchantmentCharge = -1
                end

                tes3mp.SetContainerItemEnchantmentCharge(item.enchantmentCharge)

                tes3mp.AddContainerItem()
            end

            tes3mp.AddObject()

            objectCount = objectCount + 1
        else
            tes3mp.LogAppend(3, "- Had container packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.container, uniqueIndex)
        end
    end

    if objectCount > 0 then

        -- Set the action to SET
        tes3mp.SetObjectListAction(0)

        tes3mp.SendContainer()
    end
end

function BaseCell:SendActorList(pid)

    local actorCount = 0

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.actorList) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) then
            tes3mp.SetActorRefId(self.data.objectData[uniqueIndex].refId)

            actorCount = actorCount + 1
        else
            tes3mp.LogAppend(3, "- Had actorList packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.actorList, uniqueIndex)
        end
    end

    if actorCount > 0 then

        -- Set the action to SET
        tes3mp.SetActorListAction(0)

        tes3mp.SendActorList()
    end
end

function BaseCell:SendActorAuthority(pid)

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    tes3mp.SendActorAuthority()
end

function BaseCell:SendActorPositions(pid)

    local actorCount = 0

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.position) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) then
            local location = self.data.objectData[uniqueIndex].location

            -- Ensure data integrity before proceeeding
            if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
                self:ContainsPosition(location.posX, location.posY) then

                tes3mp.SetActorPosition(location.posX, location.posY, location.posZ)
                tes3mp.SetActorRotation(location.rotX, location.rotY, location.rotZ)

                tes3mp.AddActor()

                actorCount = actorCount + 1
            end
        else
            tes3mp.LogAppend(3, "- Had position packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.position, uniqueIndex)
        end
    end

    if actorCount > 0 then
        tes3mp.SendActorPosition()
    end
end

function BaseCell:SendActorStatsDynamic(pid)

    local actorCount = 0

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.statsDynamic) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) and self.data.objectData[uniqueIndex].stats ~= nil then
            local stats = self.data.objectData[uniqueIndex].stats

            tes3mp.SetActorHealthBase(stats.healthBase)
            tes3mp.SetActorHealthCurrent(stats.healthCurrent)
            tes3mp.SetActorHealthModified(stats.healthModified)
            tes3mp.SetActorMagickaBase(stats.magickaBase)
            tes3mp.SetActorMagickaCurrent(stats.magickaCurrent)
            tes3mp.SetActorMagickaModified(stats.magickaModified)
            tes3mp.SetActorFatigueBase(stats.fatigueBase)
            tes3mp.SetActorFatigueCurrent(stats.fatigueCurrent)
            tes3mp.SetActorFatigueModified(stats.fatigueModified)

            tes3mp.AddActor()

            actorCount = actorCount + 1
        else
            tes3mp.LogAppend(3, "- Had statsDynamic packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.statsDynamic, uniqueIndex)
        end
    end

    if actorCount > 0 then
        tes3mp.SendActorStatsDynamic()
    end
end

function BaseCell:SendActorEquipment(pid)

    local actorCount = 0

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.equipment) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) and self.data.objectData[uniqueIndex].equipment ~= nil then
            local equipment = self.data.objectData[uniqueIndex].equipment

            for itemIndex = 0, tes3mp.GetEquipmentSize() - 1 do

                local currentItem = equipment[itemIndex]

                if currentItem ~= nil then
                    if currentItem.enchantmentCharge == nil then
                        currentItem.enchantmentCharge = -1
                    end

                    tes3mp.EquipActorItem(itemIndex, currentItem.refId, currentItem.count,
                        currentItem.charge, currentItem.enchantmentCharge)
                else
                    tes3mp.UnequipActorItem(itemIndex)
                end
            end

            tes3mp.AddActor()

            actorCount = actorCount + 1
        else
            tes3mp.LogAppend(3, "- Had equipment packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.equipment, uniqueIndex)
        end
    end

    if actorCount > 0 then
        tes3mp.SendActorEquipment()
    end
end

function BaseCell:SendActorAI(pid)

    if self.data.packets.ai == nil then
        self.data.packets.ai = {}
    end

    local actorCount = 0

    -- These packets only need to be sent to the new visitor, unless the
    -- new visitor is the target of some of them, in which case those
    -- need to be tracked and sent separately to all the cell's visitors
    local sharedPacketUniqueIndexes = {}

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.ai) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        if self:ContainsObject(uniqueIndex) and self.data.objectData[uniqueIndex].ai ~= nil then
            local ai = self.data.objectData[uniqueIndex].ai
            local targetPid

            if ai.targetPlayer ~= nil then
                if logicHandler.IsPlayerNameLoggedIn(ai.targetPlayer) then
                    targetPid = logicHandler.GetPlayerByName(ai.targetPlayer).pid
                end
            end

            local isValid = true

            -- Don't allow untargeted packets that require targets
            if targetPid == nil and ai.targetUniqueIndex == nil then
                if ai.action == enumerations.ai.ACTIVATE or ai.action == enumerations.ai.COMBAT or
                    ai.action == enumerations.ai.ESCORT or ai.action == enumerations.ai.FOLLOW then

                    isValid = false
                    tes3mp.LogAppend(2, "- Could not find valid AI target for actor " .. uniqueIndex)
                end
            end

            if isValid then
                -- Is this new visitor the target of one of the actors? If so, we'll
                -- send a separate packet to every cell visitor with just that at
                -- the end
                if pid == targetPid then
                    table.insert(sharedPacketUniqueIndexes, uniqueIndex)
                else
                    packetBuilder.AddAIActorToPacket(uniqueIndex, ai.action, targetPid, ai.targetUniqueIndex,
                        ai.posX, ai.posY, ai.posZ, ai.distance, ai.duration, ai.shouldRepeat)

                    actorCount = actorCount + 1
                end
            end
        else
            tes3mp.LogAppend(3, "- Had AI packet recorded for " .. uniqueIndex ..
                ", but no matching object data! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.equipment, uniqueIndex)
        end
    end

    -- Send the packets meant for just this new visitor
    if actorCount > 0 then
        tes3mp.SendActorAI(false)
    end

    -- Send the packets targeting this visitor that all the visitors
    -- need to have
    if tableHelper.getCount(sharedPacketUniqueIndexes) > 0 then
        
        tes3mp.ClearActorList()
        tes3mp.SetActorListPid(pid)
        tes3mp.SetActorListCell(self.description)

        for arrayIndex, uniqueIndex in pairs(sharedPacketUniqueIndexes) do

            local splitIndex = uniqueIndex:split("-")
            tes3mp.SetActorRefNum(splitIndex[1])
            tes3mp.SetActorMpNum(splitIndex[2])
            local ai = self.data.objectData[uniqueIndex].ai
            packetBuilder.AddAIActorToPacket(uniqueIndex, ai.action, pid, nil,
                nil, nil, nil, ai.distance, ai.duration)
        end

        tes3mp.SendActorAI(true)
    end
end

function BaseCell:SendActorCellChanges(pid)

    local temporaryLoadedCells = {}
    local actorCount = 0

    -- Move actors originally from this cell to other cells
    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    for arrayIndex, uniqueIndex in pairs(self.data.packets.cellChangeTo) do

        local splitIndex = uniqueIndex:split("-")
        tes3mp.SetActorRefNum(splitIndex[1])
        tes3mp.SetActorMpNum(splitIndex[2])

        local newCellDescription = self.data.objectData[uniqueIndex].cellChangeTo

        if newCellDescription ~= nil then
            tes3mp.SetActorCell(newCellDescription)

            -- If the new cell is not loaded, load it temporarily
            if LoadedCells[newCellDescription] == nil then
                logicHandler.LoadCell(newCellDescription)
                table.insert(temporaryLoadedCells, newCellDescription)
            end

            if LoadedCells[newCellDescription].data.objectData[uniqueIndex] ~= nil then

                local location = LoadedCells[newCellDescription].data.objectData[uniqueIndex].location

                -- Ensure data integrity before proceeeding
                if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and
                    self:ContainsPosition(location.posX, location.posY) then

                    tes3mp.SetActorPosition(location.posX, location.posY, location.posZ)
                    tes3mp.SetActorRotation(location.rotX, location.rotY, location.rotZ)

                    tes3mp.AddActor()

                    actorCount = actorCount + 1
                end
            else
                tes3mp.LogAppend(3, "- Tried to move " .. uniqueIndex .. " from " .. self.description ..
                    " to  " .. newCellDescription .. " with no position data!")
                self.data.objectData[uniqueIndex] = nil
                tableHelper.removeValue(self.data.packets.cellChangeTo, uniqueIndex)
            end
        else
            tes3mp.LogAppend(3, "- Had cellChangeTo packet recorded for " .. uniqueIndex ..
                ", but no matching cell description! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.cellChangeTo, uniqueIndex)
        end
    end

    if actorCount > 0 then
        tes3mp.SendActorCellChange()
    end

    -- Go through every temporary loaded cell and unload it
    for arrayIndex, newCellDescription in pairs(temporaryLoadedCells) do
        logicHandler.UnloadCell(newCellDescription)
    end

    -- Make a table of every cell that has sent actors to this cell
    local cellChangesFrom = {}

    for arrayIndex, uniqueIndex in pairs(self.data.packets.cellChangeFrom) do

        if self.data.objectData[uniqueIndex] ~= nil and self.data.objectData[uniqueIndex].cellChangeFrom ~= nil then
            local originalCellDescription = self.data.objectData[uniqueIndex].cellChangeFrom

            if cellChangesFrom[originalCellDescription] == nil then
                cellChangesFrom[originalCellDescription] = {}
            end

            table.insert(cellChangesFrom[originalCellDescription], uniqueIndex)
        else
            tes3mp.LogAppend(3, "- Had cellChangeFrom packet recorded for " .. uniqueIndex ..
                ", but no matching cell description! Please report this to a developer")
            tableHelper.removeValue(self.data.packets.cellChangeFrom, uniqueIndex)
        end
    end

    local actorCount = 0

    -- Send a cell change packet for every cell that has sent actors to this cell
    for originalCellDescription, actorArray in pairs(cellChangesFrom) do

        tes3mp.ClearActorList()
        tes3mp.SetActorListPid(pid)
        tes3mp.SetActorListCell(originalCellDescription)

        for arrayIndex, uniqueIndex in pairs(actorArray) do

            local splitIndex = uniqueIndex:split("-")
            tes3mp.SetActorRefNum(splitIndex[1])
            tes3mp.SetActorMpNum(splitIndex[2])

            tes3mp.SetActorCell(self.description)

            local location = self.data.objectData[uniqueIndex].location

            -- Ensure data integrity before proceeeding
            if tableHelper.getCount(location) == 6 and tableHelper.usesNumericalValues(location) and 
                self:ContainsPosition(location.posX, location.posY) then

                tes3mp.SetActorPosition(location.posX, location.posY, location.posZ)
                tes3mp.SetActorRotation(location.rotX, location.rotY, location.rotZ)

                tes3mp.AddActor()

                actorCount = actorCount + 1
            end
        end

        if actorCount > 0 then
            tes3mp.SendActorCellChange()
        end
    end
end

function BaseCell:RequestContainers(pid, requestUniqueIndexes)

    self.isRequestingContainers = true
    self.containerRequestPid = pid

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(self.description)

    -- Set the action to REQUEST
    tes3mp.SetObjectListAction(3)

    -- If certain uniqueIndexes are specified, iterate through them and
    -- add them as world objects
    --
    -- Otherwise, the client will simply reply with the contents of all
    -- the containers in this cell
    if requestUniqueIndexes ~= nil and type(requestUniqueIndexes) == "table" then
        for arrayIndex, uniqueIndex in pairs(requestUniqueIndexes) do

            local splitIndex = uniqueIndex:split("-")
            tes3mp.SetObjectRefNum(splitIndex[1])
            tes3mp.SetObjectMpNum(splitIndex[2])
            tes3mp.SetObjectRefId(self.data.objectData[uniqueIndex].refId)
            tes3mp.AddObject()
        end
    end

    tes3mp.SendContainer()
end

function BaseCell:RequestActorList(pid)

    self.isRequestingActorList = true
    self.actorListRequestPid = pid

    tes3mp.ClearActorList()
    tes3mp.SetActorListPid(pid)
    tes3mp.SetActorListCell(self.description)

    -- Set the action to REQUEST
    tes3mp.SetActorListAction(3)

    tes3mp.SendActorList()
end

function BaseCell:SendInitialCellData(pid)

    self:EnsurePacketValidity()

    tes3mp.LogMessage(1, "Sending data of cell " .. self.description .. " to pid " .. pid)

    self:SendObjectsDeleted(pid)
    self:SendObjectsPlaced(pid)
    self:SendObjectsSpawned(pid)
    self:SendObjectsLocked(pid)
    self:SendObjectTrapsTriggered(pid)
    self:SendObjectsScaled(pid)
    self:SendObjectStates(pid)
    self:SendDoorStates(pid)

    if self:HasContainerData() == true then
        tes3mp.LogAppend(1, "- Had container data")
        self:SendContainers(pid)
    elseif self.isRequestingContainers == false then
        tes3mp.LogAppend(1, "- Requesting containers")
        self:RequestContainers(pid)
    end

    if self:HasActorData() == true then
        tes3mp.LogAppend(1, "- Had actor data")
        self:SendActorCellChanges(pid)
        self:SendActorEquipment(pid)
        self:SendActorAI(pid)
    elseif self.isRequestingActorList == false then
        tes3mp.LogAppend(1, "- Requesting actor list")
        self:RequestActorList(pid)
    end
end

function BaseCell:SendMomentaryCellData(pid)

    if self:HasActorData() == true then
        self:SendActorPositions(pid)
        self:SendActorStatsDynamic(pid)
    end
end

return BaseCell
