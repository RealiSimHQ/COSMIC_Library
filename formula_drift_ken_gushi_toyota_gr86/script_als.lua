

-- Multi-Stage Anti-Lag System (ALS) for Assetto Corsa
-- Purpose: Simulates real rally car ALS with stages: Armed (Idle) -> Ready -> Engaged (holds 4500 RPM)
-- Stores stage via ac.store("ALS_stage") for display script
-- Author: Adapted for Assetto Corsa modding, based on SwitchPro/Ustahl throttle model
-- Requirements: CSP with extended-2 mode, script.lua in data folder
-- Date: September 12, 2025

-- Get UI state (for compatibility)
local cspUI = ac.getUI()



-- Define script variables
local systemArmed = false -- Overall ALS armed (toggled by Extra A)
local inReadyStage = false -- Ready stage (throttle > 0.4 AND RPM > 5700)
local inEngagedStage = false -- Engaged stage (ready AND throttle < 0.1)
local targetRPM = 2700 -- Target RPM during engagement
local throttleAdjust = 0 -- Throttle adjustment for engagement
local lastExtraAState = false -- Tracks Extra A toggle state
local endTime = 0 -- End time for 6s auto-disengage (using os.clock)
local initTimer = 1.0 -- Initialization delay for Extra A
local lastStage = -1 -- Tracks last stored stage to avoid redundant writes


local carPh = ac.accessCarPhysics()
local trottleCurve = ac.DataLUT11.carData(car.index, 'throttle.lut')

local minBoost = 0.0
local maxBoost = 1.8
local turboLag = 0.998
local antilag = 0.8
local antilagTime = 0.002

local antilagCounter = 0
local finalBoost = 0

local rpmLut = ac.DataLUT11.parse('1=-0.3|2=0|4=1.3|6=1.7|8=1.4')
rpmLut.useCubicInterpolation = true
rpmLut.extrapolate = true

local exchangeTurbo = ac.connect({
	ac.StructItem.key('extaudio:%d.turbo' % car.index),
	minTurboBoost = ac.StructItem.float()
}, true, ac.SharedNamespace.Shared)

local function reset()
	finalBoost = 0
end





-- Initialize the script
function script.init()
    if not ac.accessCarPhysics then
        ac.log("Error: Custom Shaders Patch (CSP) is required!")
        return
    end
    if not ac.overrideGasInput then
        ac.log("Error: ac.overrideGasInput not available!")
        return
    end
    if not ac.getCar then
        ac.log("Error: ac.getCar not available, cannot detect Extra A!")
        return
    end
    if not ac.setFuelRate then
        ac.log("Warning: ac.setFuelRate not available, pops/bangs may be limited")
    end
    -- Initialize ALS stage
    ac.store("ALS_stage", 0) -- Start with OFF






    ac.log("ALS Script Initialized")
end










-- Sigmoid-based throttle curve (inspired by SwitchPro/Ustahl)
local engine_ini = ac.INIConfig.carData(0, "engine.ini")
local redline = engine_ini:get("ENGINE_DATA", "LIMITER", 10000)
local gamma = 1.4 -- Tuned for smooth response
local slope = 4.0 -- Tuned for sharp throttle

local function calculateALSThrottle(rpm)
    return ((2/(1+(math.exp(-((redline/rpm)^gamma)*slope*1)))-1))/((2/(1+(math.exp(-((redline/rpm)^gamma)*slope*1)))-1))
end

local data = ac.accessCarPhysics()
local engineINI = ac.INIConfig.carData(car.index, 'engine.ini')

---Turbo acting similar to original Kunos turbo with CSP extensions. Only for illustrative purposes.
---@return fun(dt: number)
local DefaultTurbo = function (index)
  local section = 'TURBO_'..index
  local gamma = engineINI:get(section, 'GAMMA', 2)
  local rpmRef = engineINI:get(section, 'REFERENCE_RPM', 2000)
  local lagDown = engineINI:get(section, 'LAG_DN', 0.99)
  local lagUp = engineINI:get(section, 'LAG_UP', 0.99)
  local wastegate = engineINI:get(section, 'WASTEGATE', 0)
  local maxBoost = engineINI:get(section, 'MAX_BOOST', 1)
  local controllerMaxBoost = ac.getDynamicController('ctrl_turbo'..index..'.ini')
  local controllerWastegate = ac.getDynamicController('ctrl_wastegate'..index..'.ini')
  local gasCurve = engineINI:tryGetLut(section, 'EXT_GAS_CURVE')
  local spinDelay = engineINI:get(section, 'EXT_SPIN_DELAY', 0)
  local spinning = 0
  ac.log('found turbo:', index)
  return function (dt)
    if controllerMaxBoost then
      maxBoost = controllerMaxBoost()
    end
    if controllerWastegate then
      wastegate = controllerWastegate()
    end

    local gas = data.gas
    if gasCurve then
      gas = gasCurve:get(gas)
    end
    ac.debug("gas:", gas)
  -- ac.log('working turbo:', index)
    local intensity = math.pow(math.saturateN(data.rpm * gas / rpmRef), gamma)
    spinning = spinning + (intensity - spinning) * (intensity > spinning and lagUp or lagDown) * dt

    if wastegate ~= 0 then
      local adjustedWastegate = wastegate * ac.getTurboUserWastegate(index)
      if maxBoost * spinning > adjustedWastegate then
        spinning = adjustedWastegate / maxBoost
      end
    end
    minBoost = exchangeTurbo.minTurboBoost or 0
    spinning = math.max(spinning, minBoost)
    local finalBoost = math.max(maxBoost * (spinning * (1 + spinDelay) - spinDelay), minBoost)
   -- local finalBoost = maxBoost * (spinning * (1 + spinDelay) - spinDelay)
    ac.overrideTurboBoost(index, finalBoost)
    -- ac.debug("final boost: ", finalBoost)

    -- Of course final version shouldn’t have this debugging data printed:
    ac.debug('minboost', minBoost)
    ac.debug('intensity', intensity)
    ac.debug('spinning', spinning)
    ac.debug('wastegate', wastegate)
    ac.debug('boost:'..index, finalBoost)
    -- ac.log('turboboost', finalBoost)
  end
end

local function fire_antilag(dt)
	local boostController = minBoost + (maxBoost - minBoost) * ac.getTurboUserWastegate(0)
 	-- ac.log("wastegate: ", ac.getTurboUserWastegate(0)) 
	local actualTrottle = trottleCurve:get(carPh.gas * 100) / 100
	local rpmK = carPh.rpm / 1000
	local boostMult = (1 + finalBoost) * (rpmK * (actualTrottle) + 2 * (1 - actualTrottle))
	local turboLagMult = 1 - math.saturate(turboLag)

	local trottleMult = math.max(actualTrottle, antilag * math.pow(antilagCounter, 0.5))

	local targetBoost = rpmLut:get(rpmK) * math.pow(trottleMult, 0.5) - (1 - math.pow(trottleMult, 0.5))
	-- local targetBoost = 0.9
	finalBoost = finalBoost + (targetBoost - finalBoost) * boostMult * turboLagMult

	-- finalBoost = math.clamp(finalBoost, 0 + actualTrottle / 2, boostController)

	antilagCounter = actualTrottle < antilag and antilagCounter - antilagTime or antilagCounter + 0.01
	antilagCounter = math.saturate(antilagCounter) * math.saturate(rpmK - 1)
	-- ac.log("overriding boost:" , finalBoost)
	finalBoost = 1.8
	-- ac.overrideTurboBoost(0, finalBoost, finalBoost)

	-- exchangeTurbo.antiLagPitch = actualTrottle < antilag and 0.9 + rpmK / 30 or 1
	exchangeTurbo.minTurboBoost = 1.0
end



ac.log('going through turbos')
local turbos = {}
for i, section in engineINI:iterate('TURBO') do
  if engineINI:tryGetLut(section, 'MAP_0') then
    turbos[i] = MapTurbo(i - 1)
    
    ac.log('map turbo')
  else
    ac.log('default turbo')
    turbos[i] = DefaultTurbo(i - 1)
  end
end




-- Update function called every frame
function script.update(dt)

     if (car.speedKmh < 10) then
	targetRPM = ac.getScriptSetupValue("VB_ALS_RPM")() or targetRPM
     end
    -- Update initialization timer
    initTimer = initTimer - dt
    if initTimer > 0 then
        ac.debug("Initializing, skipping input check: ", initTimer)
        return
    end

    -- Get car physics and input data
    local car = ac.accessCarPhysics()
    local carInputs = ac.getCar()
    if not car or not carInputs then
        ac.log("Error: Could not access car physics or input data")
        return
    end

    -- Check for Extra A toggle (true/false state)
    local extraA = carInputs.extraA or false
    ac.debug("Extra A State: ", extraA)

    -- Toggle ALS system on Extra A state change
    if extraA ~= lastExtraAState then
        systemArmed = not systemArmed
        ac.log("ALS Armed: " .. (systemArmed and "ON" or "OFF"))
        inReadyStage = false
        inEngagedStage = false
        endTime = 0
        throttleAdjust = 0
        if ac.setFuelRate then
            ac.setFuelRate(1.0) -- Reset fuel rate
            ac.log("Reset fuel rate")
        end
    end
    lastExtraAState = extraA

    -- ALS Logic (only if armed)
    if systemArmed then
        local currentRPM = car.rpm
        local gasInput = car.gas

        -- Enter Ready Stage: throttle > 0.4 AND RPM > 5700
        if not inReadyStage and gasInput > 0.4 and currentRPM > 5700 then
            inReadyStage = true
            inEngagedStage = false
            endTime = 0
            ac.log("ALS: Entered Ready Stage")
        end

        -- Enter Engaged Stage: in ready AND throttle < 0.1
        if inReadyStage and gasInput < 0.1 then
            if not inEngagedStage then
                inEngagedStage = true
                endTime = os.clock() + 6 -- Set 6s timeout
                ac.log("ALS: Entered Engaged Stage (holding 4500 RPM)")
            end
        end

        -- Disengage from Engaged Stage
        if inEngagedStage then
            local disengage = false
            if gasInput > 0.1 then
                disengage = true
                ac.log("ALS: Disengaged (throttle > 10%) - Back to Ready")
            elseif os.clock() >= endTime then
                disengage = true
                inReadyStage = false
                ac.log("ALS: Auto-disengaged (6s timeout) - Back to Idle")
            end

            if disengage then
                inEngagedStage = false
                throttleAdjust = 0
                endTime = 0
		-- ac.overrideTurboBoost(0, nil, nil)
		
		exchangeTurbo.minTurboBoost = 0
                if ac.setFuelRate then
                    ac.setFuelRate(1.0)
                end
            else
                -- Apply fuel rate for pops
                if ac.setFuelRate then
                    ac.setFuelRate(1.8)
                    ac.log("Set fuel rate for pops")
                end
            end
        end

        -- Throttle Override: Only in Engaged Stage
        if inEngagedStage then
            if currentRPM < targetRPM then
                local sigmoidBase = calculateALSThrottle(currentRPM)
                throttleAdjust = math.min(throttleAdjust + 0.3 * dt / 0.016 * sigmoidBase, 1)
            elseif currentRPM > targetRPM then
                throttleAdjust = math.max(throttleAdjust - 0.3 * dt / 0.016, 0)
            end
            if gasInput < throttleAdjust then
                ac.overrideGasInput(throttleAdjust)
               --  ac.log("ALS Throttle: " .. throttleAdjust)
            else
                ac.overrideGasInput(gasInput)
            end
	  exchangeTurbo.minTurboBoost = 0.5
	    -- fire_antilag(dt)

        else
            ac.overrideGasInput(gasInput)
            throttleAdjust = 0
        end
    else
        ac.overrideGasInput(car.gas)
        throttleAdjust = 0
	exchangeTurbo.minTurboBoost = 0
        if ac.setFuelRate then
            ac.setFuelRate(1.0)
        end
    end

    -- Store ALS stage on change
    local stage = inEngagedStage and 3 or inReadyStage and 2 or systemArmed and 1 or 0
    if stage ~= lastStage then
        ac.store("ALS_stage", stage) -- Store stage (0=OFF, 1=ARMED, 2=READY, 3=ENGAGED)
        ac.debug("ALS Stage Stored: ", stage)
        lastStage = stage
    end

    -- Debug output
    ac.debug("ALS Armed: ", systemArmed)
    ac.debug("Ready Stage: ", inReadyStage)
    ac.debug("Engaged Stage: ", inEngagedStage)
    ac.debug("Time Left: ", endTime > 0 and (endTime - os.clock()) or 0)
    ac.debug("Current RPM: ", car.rpm)
    ac.debug("Throttle Input: ", car.gas)
    ac.debug("Throttle Output: ", throttleAdjust)
    ac.debug("exchange minboost: ", exchangeTurbo.minTurboBoost)
    
    
    
    ac.debug("turbos: ", #turbos)
-- ac.log("turbos: ", #turbos)
  for i = 1, #turbos do
	-- ac.log('going through turbos again')
	turbos[i](dt)
  end
    
    
    
end








return { update = update, reset = reset }