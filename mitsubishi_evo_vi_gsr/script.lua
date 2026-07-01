
-- Developed by RaptorJeezus --
-- LUA AYC Â© 2024 by RaptorJeezus is licensed under CC BY-NC 4.0. --
-- To view a copy of this license, visit https://creativecommons.org/licenses/by-nc/4.0/legalcode.en
-- that means use and edit this in your own projects, to your own needs, but do not commercialise even the edited version
-- throttle model by JPG, inspired by SwitchPro and UStahl


-- [THROTTLE_LUA]
-- THROTTLE_GAMMA=1.1 ; Defaults to 1.1 if not specified.
-- THROTTLE_SLOPE=2.5 ; Defaults to 2.5 if not specified.
-- IDLE_RPM=950 ; Defaults to 1000 if not specified.
-- IDLE_TYPE=0 ; 0=Cable Throttle, 1=Drive by Wire. Defaults to 0 if not specified. Also THROTTLE_TYPE
---------------------------------------------------------------------------------------------------

-- Get the redline RPM for calculations and coast torque for mode 1 --
local data = ac.accessCarPhysics()
local engine_ini = ac.INIConfig.carData(0, "engine.ini")
local redline = engine_ini:get("ENGINE_DATA", "LIMITER", 10000)
----------------------------------------------------------------------

-- Get coast values for idle model --
local idle_RPM = engine_ini:get("ENGINE_DATA", "MINIMUM", 1000)
local coast_RPM = engine_ini:get("COAST_REF", "RPM", 10000)
local coast_torque_ref = engine_ini:get("COAST_REF", "TORQUE", 80)
-----------------------------------

-- Load the power.lut (for idle model) -- note: this is quite risky and will not work properly in numerous situations. Usually error will be small though
local power_lut = engine_ini:get("HEADER", "POWER_CURVE", "")
local WOT_TORQUE = ac.DataLUT11.carData(0, power_lut)
-----------------------------------------

-- Custom parameters --
local gamma = engine_ini:get("THROTTLE_LUA", "THROTTLE_GAMMA", 1.1) -- Throttle gamma
local slope = engine_ini:get("THROTTLE_LUA", "THROTTLE_SLOPE", 2.5) -- Torque mode
local idle_type = engine_ini:get("THROTTLE_LUA", "IDLE_TYPE", engine_ini:get("THROTTLE_LUA", "THROTTLE_TYPE", 0)) -- Idle type (0 = cable, 1 = dbw)
local new_idle = engine_ini:get("THROTTLE_LUA", "IDLE_RPM", idle_RPM) -- New idle RPM
-------------------------------------------------

local enableScript = true

-- Declarations/Initializations --
local isIdleInitialized = false
local idle_model_throttle
local idle_model_trqReq

local netTorqueRequest
----------------------

local function calculateTorqueReq(throttle, rpm) -- calculates the torque request per driver throttle and rpm
    local new_throttle=1.0;
    if(rpm>0) then
        new_throttle = ((2/(1+(math.exp(-((redline/rpm)^gamma)*slope*throttle)))-1))/((2/(1+(math.exp(-((redline/rpm)^gamma)*slope*1)))-1))
    end

    return new_throttle
end

local function atanh(x) --helper fxn
    return 0.5 * math.log((1.0 + x) / (1.0 - x));
end

local function calculateTorqueInv(trqReq, rpm) --calculates the inverse of the throttle model - gets driver throttle from torque request
    if(trqReq and rpm) then
    local firstTerm = 2.0/(slope*(redline/rpm)^gamma)
    local secondTerm = atanh(trqReq*math.tanh((slope*(redline/rpm)^gamma)/2.0))
    return firstTerm*secondTerm
    else
        return 0.0
    end
end

local function calculateIdleTrqReq(new_idle_RPM) --calculates the torque request for idle
  local brkTrq = -(new_idle_RPM-idle_RPM)*(coast_torque_ref/(coast_RPM-idle_RPM))
  local engTrq = WOT_TORQUE:get(new_idle_RPM)
  return brkTrq/(brkTrq-engTrq)
end

local function _idleModelSetup()
    idle_model_trqReq = calculateIdleTrqReq(new_idle)
    idle_model_throttle = calculateTorqueInv(idle_model_trqReq,new_idle);
    isIdleInitialized = true
end

function script.update(dt)

    AYC()
    ViscousCenter() 
    ViscousFront()

    if(enableScript) then
    if not isIdleInitialized then _idleModelSetup() end

    local usedGas = data.gas;

    if(math.abs(car.gas - usedGas) > 0.1) then -- this is compensating for autoblip not being in data.gas. Should instead probably just rewrite autoblip code
        usedGas = car.gas
    end

    if idle_type == 0 then
        usedGas = usedGas*(1.0-idle_model_throttle) + idle_model_throttle;

    elseif idle_type == 1 then
        usedGas = math.max(usedGas,idle_model_throttle);
    end

    netTorqueRequest = calculateTorqueReq(usedGas, data.rpm)

    --ac.log("Idle Throttle Pedal",idle_model_throttle);
    --ac.log("Idle Throttle Torque",idle_model_trqReq);
    --ac.log("Net Throttle",usedGas);
    --ac.log("Torque Request",netTorqueRequest);
   
    ac.overrideGasInput(netTorqueRequest)

    end
    
end

-- Raptors first LUA script yaaaaaaaay
-- Use this for your project UNLESS its behind a paywall. If you paid for this script demand a refund xox
local drivetrainFile = ac.INIConfig.carData(0, "drivetrain.ini")
local torqueCalculator = 0
local distributionCalculator = 0
local aycLut = ac.DataLUT21.carData(0,"ayc_vector.2dlut")
local deltaLut = ac.DataLUT21.carData(0,"ayc_delta.2dlut") 
local aycOn = true
local lastExtraA = false

-- smoothing memory
local smoothedDeltaError = 0

function AYC()
    local data = ac.accessCarPhysics()
    local carInfo = ac.getCarPhysics()

    -- Gear ratios
    local gearRatios = {
        [-1] = -3.416, [0] = 0,
        [1] = 2.785,   [2] = 1.950,
        [3] = 1.407,   [4] = 1.031,
        [5] = 0.761
    }
    local finalDrive = 4.529
    local currentGear = ac.getCar(0).gear
    local gearRatio = gearRatios[currentGear] or 0

    -- Base torque at rear left wheel
    torqueCalculator = (data.engineTorque * finalDrive * gearRatio) / 4

    -- Base AYC speed-steering angle dependent split
    local baseDistribution = data.gas * math.clamp(car.steer, -1, 1) * (aycLut.get(aycLut, vec2(car.speedKmh, math.abs(car.steer))) - 50) / 50

    -- ==== wheel-speed delta targeting ====
    local rearLeftSpeed  = car.wheels[2].angularSpeed
    local rearRightSpeed = car.wheels[3].angularSpeed
    local steerDirection = math.sign(car.steer)
    local innerWheelSpeed, outerWheelSpeed

    if steerDirection >= 0 then
        -- right turn: right = inner
        innerWheelSpeed  = rearRightSpeed
        outerWheelSpeed  = rearLeftSpeed
    else
        -- left turn: left = inner
        innerWheelSpeed  = rearLeftSpeed
        outerWheelSpeed  = rearRightSpeed
    end

    local rearAxleDir = math.sign(rearLeftSpeed + rearRightSpeed)  -- +1 forward, -1 reverse (0 -> treat as +1)
    if rearAxleDir == 0 then rearAxleDir = 1 end

    local actualDelta  = (outerWheelSpeed - innerWheelSpeed) * rearAxleDir * steerDirection
    local desiredDelta = deltaLut.get(deltaLut, vec2(car.speedKmh, math.abs(car.steer))) * steerDirection * rearAxleDir
    local deltaError   = actualDelta - desiredDelta

    -- Deadband: ignore small errors
    if math.abs(deltaError) < 0.01 then
        deltaError = 0
    end

    -- Suppress at low speeds
    if car.speedKmh < 1 or data.gas < 0.2 then
        deltaError = 0
    end

    -- Smooth delta error (low-pass filter)
    local filterStrength = 0.01 -- higher = snappier, lower = smoother
    smoothedDeltaError = smoothedDeltaError + (deltaError - smoothedDeltaError) * filterStrength

    -- Delta influence
    local deltaGain = 0.2
    local deltaAdjustment = -smoothedDeltaError * deltaGain

    -- Final distribution
    distributionCalculator = math.clamp(baseDistribution + deltaAdjustment, -1, 1)

    -- Apply torque split
    if distributionCalculator ~= 0 and gearRatio ~= 0 then
        ac.addElectricTorque(2, torqueCalculator * distributionCalculator, true)
        ac.addElectricTorque(3, -torqueCalculator * distributionCalculator, true)
    else
        ac.addElectricTorque(2, 0, true)
        ac.addElectricTorque(3, 0, true)
    end
    ac.debug('adeltaAdjustment', deltaAdjustment)
end

local center_base_viscosity = 2  -- Base viscosity in Nm.s/rad (guess based on typical viscous LSD)
local center_viscosity_temp_coeff = 0.02  -- Viscosity increase per °C (5% per degree)
local center_ambient_temp = 20  -- Ambient temperature in °C
local center_heat_capacity = 400  -- Heat capacity in J/K (approximate for oil volume)
local center_cooling_rate = 3 -- Cooling rate in W/K (heat dissipation)
local center_max_lock_torque = 200  -- Max lock torque in Nm (adjust based on car final ratio if needed)
local center_temperature = center_ambient_temp  -- Initial temperature

function ViscousCenter()
    local data = ac.accessCarPhysics()
    local carInfo = ac.getCarPhysics()

    -- Get wheel angular speeds (rad/s)
    local front_left_angular = car.wheels[0].angularSpeed
    local front_right_angular = car.wheels[1].angularSpeed
    local rear_left_angular = car.wheels[2].angularSpeed
    local rear_right_angular = car.wheels[3].angularSpeed

    -- Calculate axle angular speeds
    local front_axle_angular = (front_left_angular + front_right_angular) / 2
    local rear_axle_angular = (rear_left_angular + rear_right_angular) / 2

    -- Speed difference in rad/s
    local axle_speed_difference = math.abs(front_axle_angular - rear_axle_angular)

    -- Current viscosity based on temperature
    local center_current_viscosity = center_base_viscosity * (1 + center_viscosity_temp_coeff * (center_temperature - center_ambient_temp))

    -- Lock torque based on viscosity and speed difference
    local center_lock_torque = center_current_viscosity * axle_speed_difference

    -- Clamp lock torque to max
    center_lock_torque = math.min(center_lock_torque, center_max_lock_torque)

    -- Simulate heating
    local center_power_dissipation = center_lock_torque * axle_speed_difference  -- Power = torque * angular speed diff (W)
    local center_temperature_change = (center_power_dissipation / center_heat_capacity) - center_cooling_rate * (center_temperature - center_ambient_temp) / center_heat_capacity
    center_temperature = center_temperature + center_temperature_change * 0.0167  -- dt ≈ 1/60 for 60 FPS

    -- Clamp temperature to reasonable range
    center_temperature = math.clamp(center_temperature, center_ambient_temp, 150)  -- Max 150°C for oil

    -- Set preload percentage for center diff (assuming controllerInputs[1] controls preload as percentage)
    data.controllerInputs[1] = center_lock_torque

    -- Optional debug
    ac.debug('axle_speed_difference', axle_speed_difference)
    ac.debug('center_temperature', center_temperature)
    ac.debug('center_lock_torque', center_lock_torque)
end

local front_base_viscosity = 1.5  -- Base viscosity in Nm.s/rad 
local front_viscosity_temp_coeff = 0.01  -- Viscosity increase per °C
local front_ambient_temp = 20  -- Ambient temperature in °C
local front_heat_capacity = 100 -- Heat capacity in J/K (approximate for oil volume)
local front_cooling_rate = 0.5 -- Cooling rate in W/K (heat dissipation)
local front_max_lock_torque = 100  -- Max lock torque in Nm (adjust based on car final ratio if needed)
local front_temperature = front_ambient_temp  -- Initial temperature

function ViscousFront()
    local data = ac.accessCarPhysics()
    local carInfo = ac.getCarPhysics()

    -- Get wheel angular speeds (rad/s)
    local front_left_angular = car.wheels[0].angularSpeed
    local front_right_angular = car.wheels[1].angularSpeed

    -- Calculate axle angular speeds
    local front_axle_angular = (front_left_angular + front_right_angular) / 2

    -- Speed difference in rad/s
    local lr_speed_difference = front_left_angular - front_right_angular

    -- Current viscosity based on temperature
    local front_current_viscosity = front_base_viscosity * (1 + front_viscosity_temp_coeff * (front_temperature - front_ambient_temp))

    -- Lock torque based on viscosity and speed difference
    local front_lock_torque = front_current_viscosity * lr_speed_difference 

    -- Clamp lock torque to max
    local front_lock_torque = math.clamp(front_current_viscosity * lr_speed_difference, -front_max_lock_torque, front_max_lock_torque)

    -- Simulate heating
    local front_power_dissipation = math.abs(front_lock_torque * lr_speed_difference) / 2  -- Power = torque * angular speed diff (W)
    local front_temperature_change = (front_power_dissipation / front_heat_capacity) - front_cooling_rate * (front_temperature - front_ambient_temp) / front_heat_capacity
    front_temperature = front_temperature + front_temperature_change * 0.0167  -- dt ≈ 1/60 for 60 FPS

    -- Clamp temperature to reasonable range
    front_temperature = math.clamp(front_temperature, front_ambient_temp, 150)  -- Max 150°C for oil

-- Apply torque split
    
    ac.addElectricTorque(0, -front_lock_torque, true)
    ac.addElectricTorque(1, front_lock_torque, true)

    -- Optional debug
    ac.debug('lr_speed_difference', lr_speed_difference)
    ac.debug('front_temperature', front_temperature)
    ac.debug('front_lock_torque', front_lock_torque)
end