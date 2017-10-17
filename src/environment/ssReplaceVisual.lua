----------------------------------------------------------------------------------------------------
-- SCRIPT TO ADJUST VISUALS DEPENDING ON SEASON
----------------------------------------------------------------------------------------------------
-- Purpose:  to add autumn/winter/spring trees and other adjustables
-- Authors:  mrbear, Rahkiin
--
-- Copyright (c) Realismus Modding, 2017
----------------------------------------------------------------------------------------------------

ssReplaceVisual = {}
g_seasons.replaceVisual = ssReplaceVisual

function ssReplaceVisual:preLoad()
    Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, ssReplaceVisual.placeableUpdatePlacableOnCreation)
end

function ssReplaceVisual:loadMap(name)
    if g_currentMission:getIsClient() then
        g_seasons.environment:addVisualSeasonChangeListener(self)

        self.loadedPlaceableDefaults = {}
        self.materialHolders = {}

        self:loadFromXML()
        self:loadMaterialHolders()

        for _, replacements in ipairs(self.modReplacements) do
            self:loadTextureIdTable(replacements)
        end
    end
end

function ssReplaceVisual:loadGameFinished()
    if g_currentMission:getIsClient() then
        self:updateFoliageLayers()
        self:updateTextures()
    end
end

--
-- XML
--

function ssReplaceVisual:loadFromXML()
    self.textureReplacements = {}
    self.textureReplacements.default = {}
    self.modReplacements = {}

    -- Default
    self:loadTextureReplacementsFromXMLFile(g_seasons.modDir .. "data/textures.xml")

    -- Modded
    for _, path in ipairs(g_seasons:getModPaths("textures")) do
        self:loadTextureReplacementsFromXMLFile(path)
    end

    if self.textureReplacements.default._foliageLayers == nil then
        self.textureReplacements.default._foliageLayers = {}
    end
end

function ssReplaceVisual:loadTextureReplacementsFromXMLFile(path)
    local file = loadXMLFile("xml", path)
    if file == nil then
        logInfo("ssReplaceVisual:", "Failed to load texture replacements configuration from " .. path)
        return
    end

    -- Load properties
    if Utils.getNoNil(getXMLBool(file, "textures#overwrite"), false) then
        self.textureReplacements = {}
        self.textureReplacements.default = {}
        self.materialHolders = {}
        self.useAlphaBlending = nil
    end

    local useAlphaBlending = getXMLBool(file, "textures#alphaBlending")
    if useAlphaBlending ~= nil then
        -- Only overwrite if actual value is supplied
        self.useAlphaBlending = useAlphaBlending
    end

    -- If there is a material holder, load that first
    local matHolder = getXMLString(file, "textures#materialHolder")
    if matHolder ~= nil then
        local baseDir = ssUtil.basedir(path)

        -- The default xml file also supplies a blending file that might be used
        local blendingMatHolder = getXMLString(file, "textures#blendingMaterialHolder")
        local blendingFile = nil

        if blendingMatHolder ~= nil then
            blendingFile = ssUtil.normalizedPath(Utils.getFilename(blendingMatHolder, baseDir))
        end

        table.insert(self.materialHolders, {
            ["default"] = ssUtil.normalizedPath(Utils.getFilename(matHolder, baseDir)),
            ["blending"] = blendingFile
        })
    end

    -- Load seasons replacements
    for seasonName, seasonId in pairs(g_seasons.util.seasonKeyToId) do
        -- Create the season if it does not exist
        if self.textureReplacements[seasonId] == nil then
            self.textureReplacements[seasonId] = {}
        end

        local season = self.textureReplacements[seasonId]

        if season._foliageLayers == nil then
            season._foliageLayers = {}
        end

        local seasonKey = "textures.seasons." .. seasonName
        if hasXMLProperty(file, seasonKey) then
            -- Read each texture replacement
            local i = 0
            while true do
                local textureKey = string.format("%s.texture(%i)", seasonKey, i)
                if not hasXMLProperty(file, textureKey) then break end

                local shapeName = getXMLString(file, textureKey .. "#shapeName")
                local secondaryNodeName = getXMLString(file, textureKey .. "#secondaryNodeName")
                local toTexture = getXMLString(file, textureKey .. "#to")

                if secondaryNodeName == nil then
                    secondaryNodeName = ""
                end

                if shapeName == nil or toTexture == nil then
                    logInfo("ssReplaceVisual:", "Failed to load texture replacements configuration from " .. path .. ": invalid format")
                    return
                end

                if season[shapeName] == nil then
                    season[shapeName] = {}
                end

                season[shapeName][secondaryNodeName] = {
                    ["replacementName"] = toTexture
                }

                i = i + 1
            end

            i = 0

            while true do
                local foliageKey = string.format("%s.foliageLayer(%i)", seasonKey, i)
                if not hasXMLProperty(file, foliageKey) then break end

                local layerName = getXMLString(file, foliageKey .. "#name")
                local toShape = getXMLString(file, foliageKey .. "#to")
                local visible = Utils.getNoNil(getXMLBool(file, foliageKey .. "#visible"), true)

                if layerName == nil or (toShape == nil and visible == true) then
                    logInfo("ssReplaceVisual:", "Failed to load foliage layer replacements configuration from " .. path .. ": invalid format")
                    return
                end

                season._foliageLayers[layerName] = {
                    ["to"] = toShape,
                    ["visible"] = visible
                }

                i = i + 1
            end
        end
    end

    delete(file)
end

function ssReplaceVisual:loadMaterialHolders()
    for _, info in ipairs(self.materialHolders) do
        local filePath

        -- Only use blending if supplied and enabled
        if info.blending ~= nil and self.useAlphaBlending then
            filePath = info.blending
        else
            filePath = info.default
        end

        local replacements = loadI3DFile(filePath)
        table.insert(self.modReplacements, replacements)

        if self.tmpMaterialHolderNodeId == nil then
            self.tmpMaterialHolderNodeId = self:findNodeByName(replacements, "summer_material_holder")
        end
    end
end

--
-- Callbacks
--

function ssReplaceVisual:visualSeasonChanged()
    self:updateTextures()
    self:updateFoliageLayers()
end

function ssReplaceVisual.placeableUpdatePlacableOnCreation(self)
    if g_currentMission:getIsClient() then
        if g_seasons.replaceVisual.loadedPlaceableDefaults[string.lower(self.configFileName)] ~= true then
            g_seasons.replaceVisual:loadMissingPlaceableDefaults(self.nodeId)

            g_seasons.replaceVisual.loadedPlaceableDefaults[string.lower(self.configFileName)] = true
        end

        ssReplaceVisual:updateTextures(self.nodeId)
    end
end

--
-- Utilities
--

-- Stefan Geiger - GIANTS Software (https://gdn.giants-software.com/thread.php?categoryId=16&threadId=664)
function ssReplaceVisual:findNodeByName(nodeId, name, skipCurrent)
    if skipCurrent ~= true and getName(nodeId) == name then
        return nodeId
    end

    for i = 0, getNumOfChildren(nodeId) - 1 do
        local tmp = self:findNodeByName(getChildAt(nodeId, i), name)

        if tmp ~= nil then
            return tmp
        end
    end

    return nil
end

function ssReplaceVisual:walkOverReplacements(default, foliage, fn)
    for seasonId, seasonTable in pairs(self.textureReplacements) do
        if default ~= false or seasonId ~= "default" then
            for shapeName, shapeNameTable in pairs(seasonTable) do
                if foliage ~= false or shapeName ~= "_foliageLayers" then
                    for secondaryNodeName, secondaryNodeTable in pairs(shapeNameTable) do
                        fn(seasonId, shapeName, secondaryNodeName)
                    end
                end
            end
        end
    end
end

function ssReplaceVisual:loadMissingPlaceableDefaults(searchBase)
    self:walkOverReplacements(false, false, function (seasonId, shapeName, secondaryNodeName)
        -- Original aterial may not be loaded yet, because, for example, a tree was not in the map
        -- but is in a Placeable
        if self.textureReplacements.default[shapeName][secondaryNodeName].materialIds == nil then
            local materialIds = ssReplaceVisual:findOriginalMaterials(searchBase, shapeName, secondaryNodeName)

            self.textureReplacements.default[shapeName][secondaryNodeName].materialIds = materialIds

            -- Load an object to hold it as well to prevent garbage collect
            if materialIds ~= nil and self.tmpMaterialHolderNodeId ~= nil then
                local nodeId = clone(self.tmpMaterialHolderNodeId, false, false, false)

                link(getRootNode(), nodeId)
                self:setShapeMaterials(nodeId, materialIds)
            end
        end
    end)
end

--
-- Texture replacement
--

-- Finds the Id for the replacement materials and adds it to self.textureReplacements.
-- Searchbase is the root node of a loaded I3D file.
-- Also used to reset to the defaults
function ssReplaceVisual:loadTextureIdTable(searchBase)
    -- Go over each texture (season, shape, secShape), find the material in the game
    -- and store its ID
    for seasonId, seasonTable in pairs(self.textureReplacements) do
        if seasonId ~= "default" then

        for shapeName, shapeNameTable in pairs(seasonTable) do
            for secondaryNodeName, secondaryNodeTable in pairs(shapeNameTable) do
                local sourceShapeId = self:findNodeByName(searchBase, secondaryNodeTable.replacementName)

                if sourceShapeId ~= nil then -- Can be defined in an other I3D file.
                    -- log("Loading mapping for texture replacement: Shapename: " .. shapeName .. " secondaryNodeName: " .. secondaryNodeName .. " searchBase: " .. searchBase .. " season: " .. seasonId .. " Value: " .. secondaryNodeTable["replacementName"] .. " materialID: " .. materialSrcId )
                    self.textureReplacements[seasonId][shapeName][secondaryNodeName].materialIds = self:getShapeMaterials(sourceShapeId)

                    -- Load the current material
                    if self.textureReplacements.default[shapeName] == nil then
                        self.textureReplacements.default[shapeName] = {}
                    end

                    if self.textureReplacements.default[shapeName][secondaryNodeName] == nil then
                        self.textureReplacements.default[shapeName][secondaryNodeName] = {}
                    end

                    if self.textureReplacements.default[shapeName][secondaryNodeName].materialIds == nil then
                        local materialIds = ssReplaceVisual:findOriginalMaterials(getRootNode(), shapeName, secondaryNodeName)
                        self.textureReplacements.default[shapeName][secondaryNodeName].materialIds = materialIds

                        -- Load an object to hold it as well to prevent garbage collect
                        if materialIds ~= nil and self.tmpMaterialHolderNodeId ~= nil then
                            local nodeId = clone(self.tmpMaterialHolderNodeId, false, false, false)

                            link(getRootNode(), nodeId)
                            self:setShapeMaterials(nodeId, materialIds)
                        end
                    end
                end
            end
        end

        if self.textureReplacements[seasonId]._foliageLayers ~= nil then
            local layers = self.textureReplacements[seasonId]._foliageLayers

            for layerName, data in pairs(layers) do
                if data.to ~= nil then
                    local node = self:findNodeByName(searchBase, data.to)

                    if node ~= nil then
                        data.materialId = getMaterial(node, 0)
                    end
                end

                -- To be able to iterate over it
                self.textureReplacements.default._foliageLayers[layerName] = 0
            end
        end

        end
    end
end

function ssReplaceVisual:getShapeMaterials(shape)
    local list = {}

    for i = 1, getNumMaterials(shape) do
        table.insert(list, getMaterial(shape, i - 1))
    end

    return list
end

function ssReplaceVisual:setShapeMaterials(shape, materialIds)
    local numMats = getNumMaterials(shape)

    for i = 1, math.min(numMats, table.getn(materialIds)) do
        setMaterial(shape, materialIds[i], i - 1)
    end
end

-- Finds the material of the original Shape object
function ssReplaceVisual:findOriginalMaterials(searchBase, shapeName, secondaryNodeName)
    -- print("Searching for object: " .. shapeName .. "/" .. secondaryNodeName .. " under " .. searchBase )
    local parentShapeId = self:findNodeByName(searchBase, shapeName)
    local childShapeId
    local materialIds

    -- print("DEBUG: " .. parentShapeId )
    if parentShapeId ~= nil then
        if secondaryNodeName == "" then
            return self:getShapeMaterials(parentShapeId)
        end

        -- Look for children. (Children only)
        childShapeId = self:findNodeByName(parentShapeId, secondaryNodeName, true)

        if childShapeId ~= nil then
            materialIds = self:getShapeMaterials(childShapeId)
        elseif getHasClassId(parentShapeId, ClassIds.SHAPE) then
            -- Use parent if child is not found, or if no LOD
            materialIds = self:getShapeMaterials(parentShapeId)
        end
    end

    return materialIds
end

-- Walks the node tree and replaces materials according to season as specified in self.textureReplacements
function ssReplaceVisual:updateTextures(nodeId)
    if nodeId == nil then
        nodeId = getRootNode()
    end

    local visualSeason = g_seasons.environment:currentVisualSeason()
    local nodeName = getName(nodeId)

    if self.textureReplacements[visualSeason][nodeName] ~= nil then
        -- If there is a texture for this season and node, set it
        for secondaryNodeName, secondaryNodeTable in pairs(self.textureReplacements[visualSeason][getName(nodeId)]) do
            if secondaryNodeName == "" then
                secondaryNodeName = nodeName
            end

            if secondaryNodeTable.materialIds ~= nil then
                -- log("Asking for texture change: " .. getName(nodeId) .. " (" .. nodeId .. ")/" .. secondaryNodeName .. " to " .. secondaryNodeTable["materialId"])
                self:updateTexturesSubNode(nodeId, secondaryNodeName, secondaryNodeTable.materialIds)
            end
        end
    elseif self.textureReplacements.default[nodeName] ~= nil then
        -- Otherwise, set the default
        for secondaryNodeName, secondaryNodeTable in pairs(self.textureReplacements.default[getName(nodeId)]) do
            if secondaryNodeName == "" then
                secondaryNodeName = nodeName
            end

            -- MATERIALID is NULL for birch
            if secondaryNodeTable.materialIds ~= nil then
                -- log("Asking for texture change: " .. getName(nodeId) .. " (" .. nodeId .. ")/" .. secondaryNodeName .. " to " .. secondaryNodeTable["materialId"])
                self:updateTexturesSubNode(nodeId, secondaryNodeName, secondaryNodeTable.materialIds)
            end
        end
    end

    -- Replace for all children recursivly
    for i = 0, getNumOfChildren(nodeId) - 1 do
        local childId = getChildAt(nodeId, i)

        if childId ~= nil then
            self:updateTextures(childId, name)
        end
    end
end

-- Does a specified replacement on subnodes of nodeId.
function ssReplaceVisual:updateTexturesSubNode(nodeId, shapeName, materialSrcIds)
    if getHasClassId(nodeId, ClassIds.SHAPE) and getName(nodeId) == shapeName then
        -- log("Setting texture for " .. getName(nodeId) .. " (" .. tostring(nodeId) .. ") to " .. tostring(materialSrcId))
        self:setShapeMaterials(nodeId, materialSrcIds)
    end

    for i = 0, getNumOfChildren(nodeId) - 1 do
        local childId = getChildAt(nodeId, i)

        if childId ~= nil then
            local tmp = self:updateTexturesSubNode(childId, shapeName, materialSrcIds)

            if tmp ~= nil then
                return tmp
            end
        end
    end

    return nil
end

--
-- Foliage updating
--

function ssReplaceVisual:updateFoliageLayers()
    local visualSeason = g_seasons.environment:currentVisualSeason()
    local layers = self.textureReplacements[visualSeason]._foliageLayers

    for layerName, defaultMaterial in pairs(self.textureReplacements.default._foliageLayers) do
        local layerId = getChild(g_currentMission.terrainRootNode, layerName)
        local seasonLayer = layers[layerName]

        if layerId ~= 0 then
            -- Load default
            if defaultMaterial == 0 then
                defaultMaterial = getMaterial(getChildAt(layerId, 0), 0)

                self.textureReplacements.default._foliageLayers[layerName] = defaultMaterial

                -- Store in a shape against GC
                if defaultMaterial ~= nil and self.tmpMaterialHolderNodeId ~= nil then
                    local nodeId = clone(self.tmpMaterialHolderNodeId, false, false, false)

                    link(getRootNode(), nodeId)
                    setMaterial(nodeId, defaultMaterial, 0)
                end
            end

            if layers[layerName] ~= nil then
                -- Set updated material. Use default if not supplied (visibility toggle only)
                if seasonLayer.materialId ~= nil then
                    self:setFoliageMaterial(layerId, seasonLayer.materialId)
                else
                    self:setFoliageMaterial(layerId, defaultMaterial)
                end

                setVisibility(layerId, seasonLayer.visible)
            else
                -- Set default material
                self:setFoliageMaterial(layerId, defaultMaterial)
                setVisibility(layerId, true)
            end
        end
    end
end

function ssReplaceVisual:setFoliageMaterial(layerId, material)
    for i = 0, getNumOfChildren(layerId) - 1 do
        setMaterial(getChildAt(layerId, i), material, 0)
    end
end
