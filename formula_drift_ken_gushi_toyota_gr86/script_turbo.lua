local exchangeTurbo = ac.connect({
	ac.StructItem.key('extaudio:%d.turbo' % car.index),
	minTurboBoost = ac.StructItem.float()
}, true, ac.SharedNamespace.Shared)

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

  ac.log('working turbo:', index)
    local intensity = math.pow(math.saturateN(data.rpm * gas / rpmRef), gamma)
    spinning = spinning + (intensity - spinning) * (intensity > spinning and lagUp or lagDown) * dt

    if wastegate ~= 0 then
      local adjustedWastegate = wastegate * ac.getTurboUserWastegate(index)
      if maxBoost * spinning > adjustedWastegate then
        spinning = adjustedWastegate / maxBoost
      end
    end
	local minBoost = exchangeTurbo.minTurboBoost or 0
    local finalBoost = Math.max(maxBoost * (spinning * (1 + spinDelay) - spinDelay), minBoost)
   -- local finalBoost = maxBoost * (spinning * (1 + spinDelay) - spinDelay)
    ac.overrideTurboBoost(index, finalBoost)
    -- ac.debug("final boost: ", finalBoost)

    -- Of course final version shouldn’t have this debugging data printed:
    ac.debug('minboost', minBoost)
    ac.debug('boost:'..index, finalBoost)
    ac.log('turboboost', finalBoost)
  end
end

---Turbo using LUTs instead of gamma and reference RPM. Based on:
---https://docs.google.com/document/d/1uBc-bHx3yiR905IoTuWzJJIMKHdtDtz1mMplsrRbyzc
---@return fun(dt: number)
local MapTurbo = function (index)
  local section = 'TURBO_'..index
  local gamma = engineINI:get(section, 'GAMMA', 2)
  local rpmRef = engineINI:get(section, 'REFERENCE_RPM', 2000)
  local lagDown = engineINI:get(section, 'LAG_DN', 0.99)
  local lagUp = engineINI:get(section, 'LAG_UP', 0.99)
  local wastegate = engineINI:get(section, 'WASTEGATE', 0)
  local maxBoost = engineINI:get(section, 'MAX_BOOST', 1)
  local controllerWastegate = ac.getDynamicController('ctrl_wastegate'..index..'.ini')
  local gasCurve = engineINI:tryGetLut(section, 'EXT_GAS_CURVE')
  local spinDelay = engineINI:get(section, 'EXT_SPIN_DELAY', 0)
  local setupItem = ac.getScriptSetupValue('MAP_TURBO_'..index) or refnumber(0)
  local spinning = 0

  ---@type ac.DataLUT11[]
  local mapNamesLut = engineINI:get(section, 'MAP_NAMES', '')
  local mapNames = {}
  if #mapNamesLut > 0 then
    local lut = ac.readDataFile(ac.getFolder(ac.FolderID.ContentCars)..'/'..ac.getCarID(car.index)..'/data/'..mapNamesLut)
    if lut and #lut > 0 then
      mapNames = table.map(table.map(lut:split('\n'), function (x)
        return x:split('|', 2, true)
      end), function (x)
        if #x ~= 2 then return end
        return x[1], tostring(x[2]) + 1
      end)
    end
  end

  local maps = {}
  for i = 0, 999 do
    local lut = engineINI:tryGetLut(section, 'MAP_'..i)
    if not lut then break end
    table.insert(maps, lut)
  end

  -- Silly trick for using user setting for switching between maps. First, set it to 100% (0 digit):
  ac.setTurboUserWastegate(index, 1)

  return function (dt)

    -- Continuing user setting trick here. Checking the current value:
    local currentUserSetting = ac.getTurboUserWastegate(index)
    if currentUserSetting ~= 1 then                                -- if it’s not 1, user changed it
      local selectedMap = math.round(currentUserSetting * 10) - 1  -- compute the new value based on whatever user has set
      ac.setTurboUserWastegate(index, 1)                           -- and reset it to 100%: this way default message wouldn’t be shown
      if maps[selectedMap + 1] then
        ac.setScriptSetupValue('MAP_TURBO_'..index, selectedMap)
        ac.setSystemMessage('Turbo', mapNames[selectedMap + 1] or ('Unnamed turbo map #'..(selectedMap + 1))) -- and we can add a custom message
      else
        ac.setSystemMessage('Turbo', 'No such map')
      end
    end

    local map = maps[setupItem() + 1]
    if not map then return end

    if map then
      maxBoost = map:get(data.rpm)
    end

    if controllerWastegate then
      wastegate = controllerWastegate()
    end

    local gas = data.gas
    if gasCurve then
      gas = gasCurve:get(gas)
    end

    local intensity = math.pow(math.saturateN(data.rpm * gas / rpmRef), gamma)
    spinning = spinning + (intensity - spinning) * (intensity > spinning and lagUp or lagDown) * dt

    if wastegate ~= 0 then
      local adjustedWastegate = wastegate * ac.getTurboUserWastegate(index)
      if maxBoost * spinning > adjustedWastegate then
        spinning = adjustedWastegate / maxBoost
      end
    end
	local minBoost = exchangeTurbo.minTurboBoost or 0
    local finalBoost = Math.max(maxBoost * (spinning * (1 + spinDelay) - spinDelay), minBoost)
    ac.log("min boost: ", minBoost)
    ac.overrideTurboBoost(index, finalBoost)

    -- Of course final version shouldn’t have this debugging data printed:
    ac.debug('boost:'..index, finalBoost)
    ac.debug('setupItem():'..index, setupItem())
    -- ac.debug('setupItem.value:'..index, setupItem.value)
  end
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

function script.update(dt)
ac.debug("turbos: ", #turbos)
ac.log("turbos: ", #turbos)
  for i = 1, #turbos do
	ac.log('going through turbos again')
	turbos[i](dt)
  end
end