----------------------------------------------------------------------------------------------------
-- SCRIPT TO UPDATE DENSITY MAPS
----------------------------------------------------------------------------------------------------
-- Purpose:  Performs updates of density maps on behalf of other modules.
-- Authors:  mrbear, Rahkiin
--
-- Copyright (c) Realismus Modding, 2017
----------------------------------------------------------------------------------------------------

ssDensityMapScanner = {}

ssDensityMapScanner.BLOCK_WIDTH = 32
ssDensityMapScanner.BLOCK_HEIGHT = 32

function ssDensityMapScanner:preLoad()
    g_seasons.dms = self
end

function ssDensityMapScanner:load(savegame, key)
    if ssXMLUtil.hasProperty(savegame, key .. ".densityMapScanner.currentJob") then
        local job = {}

        job.x = ssXMLUtil.getInt(savegame, key .. ".densityMapScanner.currentJob.x", 0)
        job.z = ssXMLUtil.getInt(savegame, key .. ".densityMapScanner.currentJob.z", -1)
        job.callbackId = ssXMLUtil.getString(savegame, key .. ".densityMapScanner.currentJob.callbackId")
        job.parameter = ssXMLUtil.getString(savegame, key .. ".densityMapScanner.currentJob.parameter")
        job.numSegments = ssXMLUtil.getInt(savegame, key .. ".densityMapScanner.currentJob.numSegments")

        self.currentJob = job

        log("[ssDensityMapScanner] Loaded current job:", job.callbackId, "with parameter", job.parameter)
    end

    -- Read queue
    self.queue = ssQueue:new()

    local i = 0
    while true do
        local ikey = string.format("%s.densityMapScanner.queue.job(%d)", key, i)
        if not ssXMLUtil.hasProperty(savegame, ikey) then break end

        local job = {}

        job.callbackId = ssXMLUtil.getString(savegame, ikey .. "#callbackId")
        job.parameter = ssXMLUtil.getString(savegame, ikey .. "#parameter")

        self.queue:push(job)

        log("[ssDensityMapScanner] Loaded queued job:", job.callbackId, "with parameter", job.parameter)

        i = i + 1
    end
end

function ssDensityMapScanner:save(savegame, key)
    removeXMLProperty(savegame, key .. ".densityMapScanner")

    if self.currentJob ~= nil then
        ssXMLUtil.setInt(savegame, key .. ".densityMapScanner.currentJob.x", self.currentJob.x)
        ssXMLUtil.setInt(savegame, key .. ".densityMapScanner.currentJob.z", self.currentJob.z)
        ssXMLUtil.setString(savegame, key .. ".densityMapScanner.currentJob.callbackId", self.currentJob.callbackId)
        ssXMLUtil.setString(savegame, key .. ".densityMapScanner.currentJob.parameter", tostring(self.currentJob.parameter))

        if self.currentJob.numSegments ~= nil then
            ssXMLUtil.setInt(savegame, key .. ".densityMapScanner.currentJob.numSegments", self.currentJob.numSegments)
        end
    end

    -- Save queue
    self.queue:iteratePushOrder(function (job, i)
        local ikey = string.format("%s.densityMapScanner.queue.job(%d)", key, i - 1)

        ssXMLUtil.setString(savegame, ikey .. "#callbackId", job.callbackId)

        if job.parameter ~= nil then
            ssXMLUtil.setString(savegame, ikey .. "#parameter", tostring(job.parameter))
        end
    end)
end

function ssDensityMapScanner:loadMap(name)
    if g_currentMission:getIsServer() then
        if self.queue == nil then
            self.queue = ssQueue:new()
        end
    end
end

function ssDensityMapScanner:loadVehiclesFinished()
    if not g_currentMission:getIsServer() then return end

    -- Quickly run any job already queued.
    while self.queue.size > 0 or self.currentJob do
        if self.currentJob == nil then
            self.currentJob = self.queue:pop()
            self.currentJob.x = 0
            self.currentJob.z = 0

            log("[ssDensityMapScanner] Dequed job:", self.currentJob.callbackId, "(", self.currentJob.parameter, ")")
        end

        while self.currentJob ~= nil do
            if not self:run(self.currentJob) then
                self.currentJob = nil
            end
        end
    end
end

function ssDensityMapScanner:update(dt)
    if not g_currentMission:getIsServer() then return end

    if self.currentJob == nil then
        self.currentJob = self.queue:pop()

        -- A new job has started
        if self.currentJob then
            self.currentJob.x = 0
            self.currentJob.z = 0

            log("[ssDensityMapScanner] Dequed job:", self.currentJob.callbackId, "(", self.currentJob.parameter, ")")
        end
    end

    if self.currentJob ~= nil then
        local num = 4 -- do 4x a 16m^2 area, for caching purposes

        -- Increase number of blocks when 4x or 16x map.
        num = num * math.floor(g_currentMission.terrainSize / 2048)

        -- Run console at half the speed of PC
        if not GS_IS_CONSOLE_VERSION then
            num = num * 2
        end

        -- When skipping night, do a bit more per frame, the player can't move anyways.
        if g_seasons.skipNight:isShowingDialog() or g_seasons.catchingUp.showWarning then
            num = num * 8
        end

        if g_dedicatedServerInfo ~= nil then
            num = g_currentMission.terrainSize / ssDensityMapScanner.BLOCK_WIDTH
        end

        for i = 1, num do
            if not self:run(self.currentJob) then
                self.currentJob = nil

                break
            end
        end
    end
end

function ssDensityMapScanner:isBusy()
    return self.queue.size > 0 or self.currentJob ~= nil
end

function ssDensityMapScanner:queueJob(callbackId, parameter)
    if g_currentMission:getIsServer() then
        log("[ssDensityMapScanner] Enqued job:", callbackId, "(", parameter, ")")

        local job = {
            callbackId = callbackId,
            parameter = parameter
        }

        if not self:foldNewJob(job) then
            self.queue:push(job)
        end
    end
end

-- Register a new DMS callback
--
-- A callback is bound to the callbackId: the name of the DMS action.
-- When a job with given callbackId is queued, func is called on target,
-- with the job parameter as last argument, after world parallelogram.
-- After the job finished, a possible finalizer is called on the target,
-- also with the job paramater.
--
-- @param callbackId String, name of jobrunner
-- @param target table, contains func and finalizer functions
-- @param func function to run for each segment of the world
-- @param finalizer function to run after all segments are run, optional
function ssDensityMapScanner:registerCallback(callbackId, target, func, finalizer, detailHeightId)
    log("[ssDensityMapScanner] Registering callback: " .. callbackId)

    if self.callbacks == nil then
        self.callbacks = {}
    end

    if detailHeightId == nil then
        detailHeightId = false
    end

    self.callbacks[callbackId] = {
        target = target,
        func = func,
        finalizer = finalizer,
        detailHeightId = detailHeightId
    }
end

-- Returns: true when new cycle needed. false when done
function ssDensityMapScanner:run(job)
    if job == nil then return end

    -- z is used for the squares since 1.3. If not available in savegame, it defaults to -1
    -- This means the job started running and should finish. New jobs don't need this.
    if job.z == -1 then
        return self:runLine(job)
    end

    local jobRunnerInfo = self.callbacks[job.callbackId]
    if jobRunnerInfo == nil then
        logInfo("[ssDensityMapScanner] Tried to run unknown callback '", job.callbackId, "'")

        return false
    end


    -- Row height (64px for caching)
    local height = ssDensityMapScanner.BLOCK_HEIGHT
    local width = ssDensityMapScanner.BLOCK_WIDTH

    local size = g_currentMission.terrainSize
    local pixelSize = size / getDensityMapSize(g_currentMission.terrainDetailHeightId)

    -- TODO: refactor, use actual density ID used.
    if not jobRunnerInfo.detailHeightId then
        pixelSize = size / getDensityMapSize(g_currentMission.terrainDetailId)
    end


    local startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ

    if jobRunnerInfo.detailHeightId then
        startWorldX = job.x * width - size / 2
        startWorldZ = job.z * height - size / 2

        widthWorldX = startWorldX + width - pixelSize
        widthWorldZ = startWorldZ

        heightWorldX = startWorldX
        heightWorldZ = startWorldZ + height - pixelSize
    else
        startWorldX = job.x * width - size / 2 + pixelSize * 0.25
        startWorldZ = job.z * height - size / 2 + pixelSize * 0.25

        widthWorldX = startWorldX + width - pixelSize * 0.5
        widthWorldZ = startWorldZ

        heightWorldX = startWorldX
        heightWorldZ = startWorldZ + height - pixelSize * 0.5
    end

    jobRunnerInfo.func(jobRunnerInfo.target, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, job.parameter)

    -- Update current job
    if job.x < (g_currentMission.terrainSize / width) - 1 then -- Starting with row 0
        -- Next row
        job.x = job.x + 1
    elseif job.z < (g_currentMission.terrainSize / height) - 1 then
        job.z = job.z + 1
        job.x = 0
    else
        -- Done with the loop, call finalizer
        if jobRunnerInfo.finalizer ~= nil then
            jobRunnerInfo.finalizer(jobRunnerInfo.target, job.parameter)
        end

        return false -- finished
    end

    return true -- not finished
end

-- Legacy version, for compatibility with existing savegames
function ssDensityMapScanner:runLine(job)
    if job == nil then return end

    local size = g_currentMission.terrainSize
    local pixelSize = size / getDensityMapSize(g_currentMission.terrainDetailHeightId)
    local startWorldX = job.x * size / job.numSegments - size / 2 + (pixelSize / 2)
    local startWorldZ = -size / 2
    local widthWorldX = startWorldX + size / job.numSegments - pixelSize
    local widthWorldZ = startWorldZ
    local heightWorldX = startWorldX
    local heightWorldZ = startWorldZ + size

    -- Run the callback
    local callback = self.callbacks[job.callbackId]
    if callback == nil then
        logInfo("[ssDensityMapScanner] Tried to run unknown callback '", job.callbackId, "'")

        return false
    end

    callback.func(callback.target, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, job.parameter)

    -- Update current job
    if job.x < job.numSegments - 1 then -- Starting with row 0
        -- Next row
        job.x = job.x + 1
    else
        -- Done with the loop, call finalizer
        if callback.finalizer ~= nil then
            callback.finalizer(callback.target, job.parameter)
        end

        return false -- finished
    end

    return true -- not finished
end

----------------------------
-- Folding
-- NOTE(Rahkiin): What I dislike about this is the coupling.
-- Now the DMS code contains stuff of classes that call the
-- DMS. Is a bit nasty. Solution is to move these fold actions
-- into the actual class that creates them.
----------------------------

--- Attempt to fold a job into the queue
-- @param job job to fold
-- @return true when folded, false when enqueueing is needed
function ssDensityMapScanner:foldNewJob(job)
    local folded = false

    if job.callbackId == "ssSnowAddSnow" or job.callbackId == "ssSnowRemoveSnow" then
        folded = self:foldSnow(job)
    elseif job.callbackId == "ssReduceStrawHay" or job.callbackId == "ssReduceGrass" then
        folded = self:foldSwath(job)
    end

    return folded
end

--- Fold a new snow job
-- @param newJob new job to fold
-- @return true when successfully folded, false otherwise
function ssDensityMapScanner:foldSnow(newJob)
    local folded = false

    local newDiff = tonumber(newJob.parameter)
    if newJob.callbackId == "ssSnowRemoveSnow" then
        newDiff = -newDiff
    end

    -- Find first snow command and adjust it
    self.queue:iteratePopOrder(function (job)
        local layers = 0

        if job.callbackId == "ssSnowAddSnow" then
            layers = tonumber(job.parameter)
        elseif job.callbackId == "ssSnowRemoveSnow" then
            layers = -1 * tonumber(job.parameter)
        end

        if layers ~= 0 then
            local newLayers = layers + newDiff

            if newLayers == 0 then
                self.queue:remove(job)
            elseif newLayers < 0 then
                job.parameter = tostring(-newLayers)
                job.callbackId = "ssSnowRemoveSnow"
            else
                job.parameter = tostring(newLayers)
                job.callbackId = "ssSnowAddSnow"
            end

            folded = true
            return true -- break
        end
    end)

    return folded
end

--- Attempt to fold a swath job
-- @param newJob new job to fold
-- @return true when successfully folded, false otherwise
function ssDensityMapScanner:foldSwath(newJob)
    local folded = false

    self.queue:iteratePopOrder(function (job)
        if job.callbackId == newJob.callbackId then
            job.parameter = tostring(tonumber(job.parameter) + tonumber(newJob.parameter))

            folded = true
            return true -- break
        end
    end)

    return folded
end
