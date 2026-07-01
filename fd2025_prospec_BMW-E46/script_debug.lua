local carIndex = 0
local car = ac.getCar(carIndex)

local LOG = true
local LOG_HZ = 20
local MASS_FALLBACK = 1325
local RHO = 1.225
local REF_AREA_FRONT = 2.10
local REF_AREA_SIDE = 5.60

local t = 0
local logTimer = 0
local file = nil
local baseCaptured = false
local baseFront, baseRear, baseTotal = 0, 0, 0
local lastLV = nil
local lastSpeed = 0

local function get(o, k, d)
  if o == nil then return d or 0 end
  local ok, v = pcall(function() return o[k] end)
  if ok and v ~= nil then return v end
  return d or 0
end

local function num(x, d)
  if x == nil then return d or 0 end
  return x
end

local function gv(v, k)
  if v == nil then return 0 end
  local ok, r = pcall(function() return v[k] end)
  if ok and r ~= nil then return r end
  return 0
end

local function degAuto(x)
  x = x or 0
  if math.abs(x) < 6.4 then return math.deg(x) end
  return x
end

local function fmt(x)
  if x == nil then return "0" end
  return tostring(x)
end

local function openLog()
  if file or not LOG then return end

  local path = ac.getFolder(ac.FolderID.ScriptConfig) .. "/ac_nerd_logger.csv"
  file = io.open(path, "w")

  if not file then
    ac.debug("LOGGER ERROR", "CSV open failed")
    LOG = false
    return
  end

  ac.debug("LOGGER PATH", path)

  file:write(table.concat({
    "time",
    "speed_kmh",
    "rpm",
    "gear",
    "gas",
    "brake",
    "clutch",
    "steer_deg",
    "drift_angle_deg",
    "yaw_rate_deg_s",
    "pitch_rate_deg_s",
    "roll_rate_deg_s",

    "load_total",
    "load_front",
    "load_rear",
    "front_pct",
    "rear_pct",
    "aero_est_total_N",
    "aero_est_front_N",
    "aero_est_rear_N",
    "aero_balance_front_pct",

    "FL_load","FR_load","RL_load","RR_load",
    "FL_fx","FR_fx","RL_fx","RR_fx",
    "FL_fy","FR_fy","RL_fy","RR_fy",
    "front_fx","rear_fx","front_fy","rear_fy",
    "total_fx","total_fy",

    "FL_mu","FR_mu","RL_mu","RR_mu",
    "front_mu_avg","rear_mu_avg",

    "FL_slip_angle_deg","FR_slip_angle_deg","RL_slip_angle_deg","RR_slip_angle_deg",
    "FL_slip_ratio","FR_slip_ratio","RL_slip_ratio","RR_slip_ratio",
    "FL_dx","FR_dx","RL_dx","RR_dx",
    "FL_dy","FR_dy","RL_dy","RR_dy",
    "FL_mz","FR_mz","RL_mz","RR_mz",

    "FL_tyre_pressure","FR_tyre_pressure","RL_tyre_pressure","RR_tyre_pressure",
    "FL_core_temp","FR_core_temp","RL_core_temp","RR_core_temp",
    "FL_inside_temp","FR_inside_temp","RL_inside_temp","RR_inside_temp",
    "FL_middle_temp","FR_middle_temp","RL_middle_temp","RR_middle_temp",
    "FL_outside_temp","FR_outside_temp","RL_outside_temp","RR_outside_temp",

    "FL_suspension_travel","FR_suspension_travel","RL_suspension_travel","RR_suspension_travel",
    "FL_camber","FR_camber","RL_camber","RR_camber",
    "FL_toe","FR_toe","RL_toe","RR_toe",

    "local_vx","local_vy","local_vz",
    "ax_local","ay_local","az_local",
    "est_side_force_from_accel_N",
    "est_long_force_from_accel_N",

    "q_front",
    "q_side",
    "est_CL_total_from_load",
    "est_CL_front_from_load",
    "est_CL_rear_from_load",
    "est_CY_from_total_fy",
    "est_CD_from_total_fx"
  }, ",") .. "\n")
end

local function writeRow(row)
  if not file then return end
  for i = 1, #row do row[i] = fmt(row[i]) end
  file:write(table.concat(row, ",") .. "\n")
end

local function mu(w)
  local fx = get(w, "fx", 0)
  local fy = get(w, "fy", 0)
  local load = math.max(get(w, "load", 0), 1)
  return math.sqrt(fx * fx + fy * fy) / load
end

function update(dt)
  if not car then car = ac.getCar(carIndex) end
  if not car or not car.wheels then return end

  local fl = car.wheels[0]
  local fr = car.wheels[1]
  local rl = car.wheels[2]
  local rr = car.wheels[3]
  if not fl or not fr or not rl or not rr then return end

  t = t + dt
  logTimer = logTimer + dt

  local speedKmh = get(car, "speedKmh", 0)
  local speedMs = speedKmh / 3.6

  local lFL = get(fl, "load", 0)
  local lFR = get(fr, "load", 0)
  local lRL = get(rl, "load", 0)
  local lRR = get(rr, "load", 0)

  local frontLoad = lFL + lFR
  local rearLoad = lRL + lRR
  local totalLoad = frontLoad + rearLoad

  if not baseCaptured and speedKmh < 2 and t > 1 then
    baseFront = frontLoad
    baseRear = rearLoad
    baseTotal = totalLoad
    baseCaptured = true
  end

  local aeroTotal = baseCaptured and totalLoad - baseTotal or 0
  local aeroFront = baseCaptured and frontLoad - baseFront or 0
  local aeroRear = baseCaptured and rearLoad - baseRear or 0
  local aeroBalance = math.abs(aeroTotal) > 5 and aeroFront / aeroTotal * 100 or 0

  local lv = get(car, "localVelocity", nil)
  local av = get(car, "localAngularVelocity", nil)

  local vx = gv(lv, "x")
  local vy = gv(lv, "y")
  local vz = gv(lv, "z")

  local driftAngle = 0
  if math.abs(vx) + math.abs(vz) > 0.2 then
    driftAngle = math.deg(math.atan2(vx, vz))
  end

  local ax, ay, az = 0, 0, 0
  if lastLV and dt > 0 then
    ax = (vx - gv(lastLV, "x")) / dt
    ay = (vy - gv(lastLV, "y")) / dt
    az = (vz - gv(lastLV, "z")) / dt
  end
  lastLV = vec3(vx, vy, vz)

  local mass = get(car, "mass", MASS_FALLBACK)
  if mass < 100 then mass = MASS_FALLBACK end

  local estSideForceAccel = mass * ax
  local estLongForceAccel = mass * az

  local flfx, frfx, rlfx, rrfx = get(fl,"fx",0), get(fr,"fx",0), get(rl,"fx",0), get(rr,"fx",0)
  local flfy, frfy, rlfy, rrfy = get(fl,"fy",0), get(fr,"fy",0), get(rl,"fy",0), get(rr,"fy",0)

  local frontFx = flfx + frfx
  local rearFx = rlfx + rrfx
  local frontFy = flfy + frfy
  local rearFy = rlfy + rrfy
  local totalFx = frontFx + rearFx
  local totalFy = frontFy + rearFy

  local q = 0.5 * RHO * speedMs * speedMs
  local qFront = q * REF_AREA_FRONT
  local qSide = q * REF_AREA_SIDE

  local estCLTotal = qFront > 1 and aeroTotal / qFront or 0
  local estCLFront = qFront > 1 and aeroFront / qFront or 0
  local estCLRear = qFront > 1 and aeroRear / qFront or 0
  local estCY = qSide > 1 and totalFy / qSide or 0
  local estCD = qFront > 1 and -totalFx / qFront or 0

local gx = ax / 9.80665
local gy = ay / 9.80665
local gz = az / 9.80665

  ac.debug("00 speed kmh", speedKmh)
  ac.debug("01 drift angle deg", driftAngle)
  ac.debug("02 total load", totalLoad)
  ac.debug("03 front load", frontLoad)
  ac.debug("04 rear load", rearLoad)

  ac.debug("05 aero est total N", aeroTotal)
  ac.debug("06 aero est front N", aeroFront)
  ac.debug("07 aero est rear N", aeroRear)
  ac.debug("08 aero balance front %", aeroBalance)

  ac.debug("10 est CL total", estCLTotal)
  ac.debug("11 est CL front", estCLFront)
  ac.debug("12 est CL rear", estCLRear)
  ac.debug("13 est CY from tyre Fy", estCY)
  ac.debug("14 est CD from tyre Fx", estCD)

  ac.debug("20 FL load", lFL)
  ac.debug("21 FR load", lFR)
  ac.debug("22 RL load", lRL)
  ac.debug("23 RR load", lRR)

  ac.debug("30 FL fx", flfx)
  ac.debug("31 FR fx", frfx)
  ac.debug("32 RL fx", rlfx)
  ac.debug("33 RR fx", rrfx)

  ac.debug("40 FL fy", flfy)
  ac.debug("41 FR fy", frfy)
  ac.debug("42 RL fy", rlfy)
  ac.debug("43 RR fy", rrfy)

  ac.debug("50 FL mu", mu(fl))
  ac.debug("51 FR mu", mu(fr))
  ac.debug("52 RL mu", mu(rl))
  ac.debug("53 RR mu", mu(rr))

  ac.debug("60 FL slip angle", degAuto(get(fl,"slipAngle",0)))
  ac.debug("61 FR slip angle", degAuto(get(fr,"slipAngle",0)))
  ac.debug("62 RL slip angle", degAuto(get(rl,"slipAngle",0)))
  ac.debug("63 RR slip angle", degAuto(get(rr,"slipAngle",0)))

  ac.debug("70 tyre pressure FL", get(fl,"tyrePressure",0))
  ac.debug("71 tyre pressure FR", get(fr,"tyrePressure",0))
  ac.debug("72 tyre pressure RL", get(rl,"tyrePressure",0))
  ac.debug("73 tyre pressure RR", get(rr,"tyrePressure",0))

ac.debug("G lateral", gx)
ac.debug("G vertical", gy)
ac.debug("G longitudinal", az / 9.80665)
ac.debug("G combined XY", math.sqrt(gx*gx + (az/9.80665)*(az/9.80665)))


end

return { update = update }