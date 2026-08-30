-- HELIOS Draconic Guardian v1.0
-- Dedicated local Draconic controller. Never install this on the normal
-- HELIOS modem bus: it owns exactly one reactor component and its two gates.

local FIELD_TARGET, FIELD_EMERGENCY = 50, 15
local MAX_TEMPERATURE, MINIMUM_FUEL = 8000, 10
-- Draconic's peripheral telemetry reports live generation but not a safe
-- maximum output. Establish one by proving progressively larger exports.
-- The calibration may approach the real limit, but never crosses the 15%
-- hard shutdown interlock: 17% is the operating-edge cutoff.
local COMMISSION_START_FLOW, COMMISSION_SAMPLES = 50000, 20
local COMMISSION_FIELD_FLOOR, COMMISSION_TEMP_LIMIT = 17, 5000
local COMMISSION_STEP_RATIO, COMMISSION_MIN_STEP = 1.25, 50000
local COMMISSION_SHORTFALL_SAMPLES = 20
-- A cool reactor ramps up to a new export request over several seconds.  This
-- is a settling period, not evidence that the output path has reached its
-- ceiling, so do not score it as a failed sample.
local COMMISSION_SETTLE_SAMPLES = 120
local FRACTION = { OFF = 0, MIN = .25, MED = .50, MAX = 1 }
local PRESET_RAMP_STEP, MANUAL_GATE_STEP, MANUAL_GATE_LARGE_STEP = 50000, 100000, 1000000
local SETTINGS = ".helios-draconic-guardian.lua"

local function hasType(name, fragment)
  for _, t in ipairs({ peripheral.getType(name) }) do
    if string.find(string.lower(tostring(t or "")), fragment, 1, true) then return true end
  end
  return false
end
local function sort(t) table.sort(t, function(a,b) return tostring(a) < tostring(b) end); return t end
local function localSides() local r = {}; for _, s in ipairs(rs.getSides()) do if peripheral.isPresent(s) then r[s] = true end end; return r end
local function inspect()
  local p, localReactors, remoteReactors, directGates, exportGates, modems, monitors = localSides(), {}, {}, {}, {}, {}, {}
  for side in pairs(p) do
    if hasType(side, "draconic_reactor") then localReactors[#localReactors+1] = side end
    if hasType(side, "flow_gate") then
      directGates[#directGates+1] = side
      -- Fixed Guardian topology: one local Flux Gate on LEFT or RIGHT is the
      -- reactor's export throttle. It never provides containment power.
      if side == "left" or side == "right" then exportGates[#exportGates+1] = side end
    end
    if hasType(side, "modem") then modems[#modems+1] = side end
    if hasType(side, "monitor") then monitors[#monitors+1] = side end
  end
  local inputs = {}; for _, n in ipairs(peripheral.getNames()) do
    if not p[n] then
      if hasType(n,"draconic_reactor") then remoteReactors[#remoteReactors+1]=n end
      if hasType(n,"flow_gate") then inputs[#inputs+1]=n end
    end
  end
  local reactors={};for _,n in ipairs(localReactors) do reactors[#reactors+1]=n end;for _,n in ipairs(remoteReactors) do reactors[#reactors+1]=n end
  sort(reactors);sort(directGates);sort(exportGates);sort(modems);sort(monitors);sort(inputs)
  local why={}; if #reactors~=1 then why[#why+1]="Require exactly one reactor component (direct or wired)" end
  if #exportGates~=1 then why[#why+1]="Require exactly one local export gate on LEFT or RIGHT (never both)" end
  if #directGates~=#exportGates then why[#why+1]="No other Flux Gate may be directly attached to the Guardian" end
  if #modems<1 then why[#why+1]="Require one local wired modem/peripheral hub" end
  -- The sole remote gate reachable through the wired modem is always the
  -- injector-feed gate. Guardian uses it only to sustain field strength.
  if #inputs~=1 then why[#why+1]="Require exactly one modem-connected injector field gate" end
  return {ready=#why==0,reasons=why,reactor=reactors[1],output=exportGates[1],modem=modems[1],monitor=monitors[1],input=inputs[1]}
end
local function call(n,m,...)
  if not n then return nil,"missing" end
  local ok,v=pcall(peripheral.call,n,m,...); if not ok then return nil,tostring(v) end; return v
end
local function read(b)
  local r,e=call(b.reactor,"getReactorInfo"); if type(r)~="table" then return nil,e or "getReactorInfo failed" end
  local inputSet=call(b.input,"getFlowOverride");if inputSet==nil then inputSet=call(b.input,"getSignalLowFlow") end
  local outputSet=call(b.output,"getFlowOverride");if outputSet==nil then outputSet=call(b.output,"getSignalLowFlow") end
  return {reactor=r,inputFlow=call(b.input,"getFlow"),outputFlow=call(b.output,"getFlow"),inputSet=inputSet,outputSet=outputSet,inputOverride=call(b.input,"getOverrideEnabled"),outputOverride=call(b.output,"getOverrideEnabled")}
end
local function gate(n,v)
  local flow=math.max(0,math.floor(tonumber(v) or 0))
  local enabled,enableError=call(n,"setOverrideEnabled",true);if enabled==nil and enableError then return false,enableError end
  local _,flowError=call(n,"setFlowOverride",flow);if flowError then return false,flowError end
  return true
end
local function positive(v) v=tonumber(v);return v and v>0 and math.floor(v) or nil end
local function adoptInjectorBaseline(d,c)
  if not positive(c.injectorBaseline) then
    -- Prefer the configured gate limit over live flow: live flow drops when
    -- the reactor is cool, but the configured limit remains the proven field
    -- support capacity selected by the operator.
    c.injectorBaseline=positive(d.inputSet) or positive(d.inputFlow)
  end
  return positive(c.injectorBaseline)
end
local function acquireGates(b,d,c)
  local injectorCap=adoptInjectorBaseline(d,c)
  if not injectorCap then
    c.gatesOwned=false;c.gateError="no positive injector gate limit to adopt"
    c.message="CONTROL LOCKED: set the injector gate manually, then restart Guardian"
    return false
  end
  if d.inputOverride==true and d.outputOverride==true then c.gatesOwned=true;c.gateError=nil;return true end
  -- Containment first, then export. Never close field support while taking control.
  local inputOk,inputError=gate(b.input,injectorCap)
  local outputOk,outputError=gate(b.output,0)
  local inputOwned=call(b.input,"getOverrideEnabled")==true
  local outputOwned=call(b.output,"getOverrideEnabled")==true
  c.gatesOwned=inputOk and outputOk and inputOwned and outputOwned
  if not c.gatesOwned then
    c.message="CONTROL LOCKED: gate override not acquired (field "..tostring(inputOwned)..", output "..tostring(outputOwned)..")"
    c.gateError=inputError or outputError
  else c.gateError=nil end
  return c.gatesOwned
end
local function reactor(n,m) return pcall(peripheral.call,n,m) end

-- A requested export is only meaningful once the core is actually online.
-- Keep the entire charge -> activate sequence in one place so the manual
-- selector, commissioning, and the explicit activation control behave alike.
local function ensureStarted(b,c,status,reason)
  gate(b.output,0)
  gate(b.input,positive(c.injectorBaseline) or 0)
  if status=="offline" or status=="stopping" or status=="cooling" then
    reactor(b.reactor,"chargeReactor")
    c.startActivated=false
    c.message=reason..": charging containment"
    return true
  end
  if status=="charging" then
    c.startActivated=false
    c.message=reason..": charging containment"
    return true
  end
  if status=="charged" or status=="warming_up" or status=="warning_up" then
    if not c.startActivated then
      reactor(b.reactor,"activateReactor")
      c.startActivated=true
    end
    c.message=reason..": activation sent; waiting for ONLINE"
    return true
  end
  if status=="online" or status=="running" then
    c.initialRequested=false
    c.startActivated=false
    return false
  end
  c.message=reason..": waiting for reactor state "..string.upper(status)
  return true
end
local function pct(a,b) if tonumber(a) and tonumber(b) and tonumber(b)>0 then return tonumber(a)/tonumber(b)*100 end end
local function clamp(x) return math.max(0,math.min(1,tonumber(x) or 0)) end
local function fmt(n)
  n=tonumber(n);if not n then return "N/A" end;local u={"","k","M","B","T","Qa"};local i=1
  while math.abs(n)>=1000 and i<#u do n=n/1000;i=i+1 end
  return string.format(math.abs(n)>=100 and "%.0f%s" or "%.2f%s",n,u[i])
end
local function text(t,x,y,s,c) local w=select(1,t.getSize());if y>=1 then t.setCursorPos(x,y);t.setTextColor(c or colors.white);t.write(string.sub(tostring(s),1,math.max(0,w-x+1))) end end
local function compactMonitor(t,isMonitor) if isMonitor and t and type(t.setTextScale)=="function" then pcall(t.setTextScale,.5) end end
-- Monitor touches report character coordinates. Keep every target on its
-- rendered row so vertically adjacent controls can never steal a press.
local function button(t,x,y,label,c,pad)
  local v="["..label.."]";text(t,x,y,v,c or colors.cyan)
  pad=math.max(0,math.floor(tonumber(pad) or 0))
  return {x1=math.max(1,x-pad),x2=x+#v-1+pad,y1=math.max(1,y-pad),y2=y+pad,x=x,y=y,label=label}
end
local function hit(bs,x,y)
  local picked, distance
  for _,b in ipairs(bs) do
    if y>=b.y1 and y<=b.y2 and x>=b.x1 and x<=b.x2 then
      local d=math.abs(y-b.y)*100+math.abs(x-(b.x+b.x2)/2)
      if not distance or d<distance then picked,distance=b,d end
    end
  end
  return picked and picked.label
end
local function vertical(t,x,y,h,label,now,maximum,c)
  local f=maximum and clamp((tonumber(now) or 0)/maximum) or 0;text(t,x,y,label,colors.lightGray)
  for row=1,h do t.setCursorPos(x,y+row);t.setBackgroundColor(row>h-math.max(1,math.floor(h*f)) and c or colors.gray);t.write("    ") end
  t.setBackgroundColor(colors.black);text(t,x,y+h+1,string.format("%3.0f%%",f*100),c)
end
local function load()
  local d={mode="AUTO",request="OFF",rated=nil,commissioned=false,commissioning=false,commissionFlow=nil,commissionSamples=0,commissionShortfallSamples=0,commissionSettleSamples=0,commissionLastSafe=nil,recovery=false,arm=0,initialRequested=false,startActivated=false,message="Automatic safe supervision"}
  if not fs.exists(SETTINGS) then return d end;local ok,s=pcall(dofile,SETTINGS);if not ok or type(s)~="table" then return d end
  d.mode=(s.mode=="ASSISTED" or s.mode=="UNRESTRICTED") and s.mode or "AUTO";d.request=(FRACTION[s.request] or s.request=="MANUAL" or s.request=="OVERDRIVE") and s.request or "OFF";d.rated=tonumber(s.rated);d.injectorBaseline=positive(s.injectorBaseline);d.manualField=positive(s.manualField);d.manualExport=positive(s.manualExport) or 0;d.overdriveField=positive(s.overdriveField);d.overdriveExport=positive(s.overdriveExport);d.commissioned=s.commissioned==true;d.message=tostring(s.message or d.message);return d
end
local function save(c) local h=fs.open(SETTINGS,"w");if h then h.write("return "..textutils.serialize(c));h.close() end end

-- AUTO and ASSISTED retain containment. UNRESTRICTED is visibly armed and lets
-- the operator's command stand, while warnings remain live.
local function supervise(b,d,c)
  local r=d.reactor;local status=string.lower(tostring(r.status or "unknown"));local field=pct(r.fieldStrength,r.maxFieldStrength) or 0
  local live=status=="online" or status=="running"
  local fuel=pct((tonumber(r.maxFuelConversion) or 0)-(tonumber(r.fuelConversion) or 0),r.maxFuelConversion) or 0;local temp=tonumber(r.temperature) or math.huge;local free=c.mode=="UNRESTRICTED"
  local injectorCap=positive(c.injectorBaseline) or 0
  local function stop(reason,charge) gate(b.output,0);reactor(b.reactor,"stopReactor");if charge then reactor(b.reactor,"chargeReactor");gate(b.input,injectorCap) end;c.message="SAFETY INTERLOCK: "..reason;return true end
  if not acquireGates(b,d,c) then
    c.initialRequested=false;c.startActivated=false;c.commissioning=false
    reactor(b.reactor,"stopReactor")
    return
  end
  if not free then
    if fuel<=MINIMUM_FUEL then return stop("fuel reserve below "..MINIMUM_FUEL.."%") end
    -- A reactor can still be draining its field while reporting "cooling".
    -- Containment must win in every state, not only when DE calls it running.
    if field<=FIELD_EMERGENCY then return stop("field below "..FIELD_EMERGENCY.."%",true) end
    if temp>MAX_TEMPERATURE then return stop("temperature above "..MAX_TEMPERATURE.." C") end
  elseif fuel<=MINIMUM_FUEL or field<=FIELD_EMERGENCY or temp>MAX_TEMPERATURE then c.message="UNRESTRICTED WARNING: a containment/fuel/temperature limit is exceeded" end
  if status=="charging" then gate(b.input,injectorCap);c.message="Charging containment";return end
  if c.initialRequested then
    if status=="offline" or status=="stopping" then
      reactor(b.reactor,"chargeReactor");gate(b.input,injectorCap);c.message="Initial start: charging containment"
      return
    end
    if not c.startActivated and (status=="charged" or status=="warming_up" or status=="warning_up") then
      -- A warming-up reactor commonly reports zero field drain.  Never use
      -- that transient value to reduce its stabilizer supply: doing so leaves
      -- the reactor at 1 RF/t and prevents it from ever reaching ONLINE.
      -- Keep containment fully supplied until live telemetry is available.
      reactor(b.reactor,"activateReactor");gate(b.input,injectorCap)
      c.startActivated=true;c.message="Initial start: activation sent; waiting for ONLINE"
      return
    end
    if live then c.initialRequested=false;c.startActivated=false;c.message="Initial start complete; reactor is live" end
  end
  if c.recovery then
    -- A calibration that reaches its edge pauses with export closed until the
    -- field has rebuilt. This prevents an old manual request from resuming.
    gate(b.output,0);gate(b.input,injectorCap)
    if field>=45 and temp<=COMMISSION_TEMP_LIMIT then
      c.recovery=false
      c.message="Calibration recovery complete; export remains OFF"
    else c.message="Calibration recovery: output closed while containment rebuilds" end
    return
  end
  if c.commissioning then
    if not live then
      c.initialRequested=true
      c.message="Automatic commissioning: waiting for reactor to reach ONLINE"
      return
    end
    local trial=math.max(COMMISSION_START_FLOW,tonumber(c.commissionFlow) or COMMISSION_START_FLOW)
    gate(b.input,injectorCap)
    gate(b.output,trial)
    -- Stop just above the hard 15% interlock. A 17% calibration cutoff leaves
    -- the guardian room to close export and rebuild the field safely.
    if field<COMMISSION_FIELD_FLOOR or temp>COMMISSION_TEMP_LIMIT or fuel<=MINIMUM_FUEL then
      gate(b.output,0);gate(b.input,injectorCap);c.commissioning=false;c.initialRequested=false;c.commissionSamples=0;c.commissionShortfallSamples=0;c.commissionSettleSamples=0;c.request="OFF";c.recovery=true
      c.commissioned=tonumber(c.commissionLastSafe) and c.commissionLastSafe>0 or false;c.rated=c.commissionLastSafe
      c.message="Calibration reached the 17% field edge; output closed. Last verified ceiling "..fmt(c.rated or 0).." RF/t"
      return
    end
    -- A Flux Gate's reported flow is not a trustworthy measure of reactor
    -- generation on every DE/ATM configuration.  The reactor component is
    -- authoritative: only count a trial as proven when its generation rate
    -- actually follows the requested export.
    local generation=tonumber(r.generationRate) or 0
    local stable=field>=45 and temp<=COMMISSION_TEMP_LIMIT and fuel>MINIMUM_FUEL and generation>=trial*.9
    if generation<trial*.9 then
      c.commissionSamples=0
      c.commissionSettleSamples=(tonumber(c.commissionSettleSamples) or 0)+1
      if c.commissionSettleSamples<COMMISSION_SETTLE_SAMPLES then
        c.commissionShortfallSamples=0
        c.message="Waiting for "..fmt(trial).." RF/t to settle: reactor generation "..fmt(generation).." RF/t ("..c.commissionSettleSamples.."/"..COMMISSION_SETTLE_SAMPLES..")"
        return
      end
      c.commissionSamples=0;c.commissionShortfallSamples=(tonumber(c.commissionShortfallSamples) or 0)+1
      if c.commissionShortfallSamples>=COMMISSION_SHORTFALL_SAMPLES then
        gate(b.output,0);c.commissioning=false;c.initialRequested=false;c.request="OFF";c.commissioned=(tonumber(c.commissionLastSafe) or 0)>0;c.rated=c.commissionLastSafe
        c.message="Calibration complete: output path stopped accepting higher export; verified ceiling "..fmt(c.rated or 0).." RF/t"
      else c.message="Testing "..fmt(trial).." RF/t: reactor generation "..fmt(generation).." RF/t ("..c.commissionShortfallSamples.."/"..COMMISSION_SHORTFALL_SAMPLES..")" end
      return
    end
    c.commissionSettleSamples=0;c.commissionShortfallSamples=0;c.commissionSamples=stable and (tonumber(c.commissionSamples) or 0)+1 or 0
    if c.commissionSamples>=COMMISSION_SAMPLES then
      c.rated=trial;c.commissionLastSafe=trial;c.commissionSamples=0;c.commissionSettleSamples=0
      c.commissionFlow=math.max(trial+COMMISSION_MIN_STEP,math.floor(trial*COMMISSION_STEP_RATIO))
      c.message="Calibration proved "..fmt(trial).." RF/t; advancing to "..fmt(c.commissionFlow).." RF/t"
    else
      c.message="Calibrating "..fmt(trial).." RF/t: stable sample "..c.commissionSamples.."/"..COMMISSION_SAMPLES
    end
    return
  end
  if c.mode=="AUTO" then gate(b.input,injectorCap);gate(b.output,0);c.message="Automatic: adopted "..fmt(injectorCap).." RF/t injector limit; export closed";return end
  if not c.commissioned or not c.rated then c.message="Control locked: run automatic commissioning first";return end
  -- Manual Gates and the saved Overdrive preset use the operator's exact
  -- field/export pair. Overdrive ramps only its export value so a cold core
  -- can gain efficiency instead of being hit with the whole load at once.
  if c.request=="MANUAL" or c.request=="OVERDRIVE" then
    local fieldTarget=positive(c.request=="OVERDRIVE" and c.overdriveField or c.manualField) or injectorCap
    local exportTarget=positive(c.request=="OVERDRIVE" and c.overdriveExport or c.manualExport) or 0
    if status=="offline" or status=="stopping" or status=="cooling" then reactor(b.reactor,"chargeReactor");gate(b.input,fieldTarget);c.message="Charging containment for manual gate targets";return end
    if status=="charged" then reactor(b.reactor,"activateReactor");gate(b.input,fieldTarget);c.message="Starting for manual gate targets";return end
    if live then
      gate(b.input,fieldTarget)
      local applied=exportTarget
      if c.request=="OVERDRIVE" then
        local previous=tonumber(c.overdriveApplied) or 0
        -- Hold instead of climbing whenever containment is below its normal
        -- operating target; the saved preset is never silently replaced.
        if field>=FIELD_TARGET then previous=math.min(exportTarget,previous+PRESET_RAMP_STEP) end
        c.overdriveApplied=previous;applied=previous
        c.message="Overdrive preset ramp: "..fmt(applied).." / "..fmt(exportTarget).." RF/t"
      else c.message="Manual gates applied: field "..fmt(fieldTarget)..", export "..fmt(exportTarget).." RF/t" end
      gate(b.output,applied)
      return
    end
  end
  if c.request=="OFF" then gate(b.output,0);reactor(b.reactor,"stopReactor");c.message="Manual OFF: export closed";return end
  if status=="offline" or status=="stopping" or status=="cooling" then
    -- Cooling is the post-stop state in DE. Treat it as a restart state so a
    -- selected output cannot leave the Guardian waiting forever with export
    -- closed and residual generation still visible in telemetry.
    reactor(b.reactor,"chargeReactor");gate(b.input,injectorCap);c.message="Charging containment for requested output";return
  end
  if status=="charged" then reactor(b.reactor,"activateReactor");c.message="Starting for requested output";return end
  if live then gate(b.input,injectorCap);gate(b.output,c.rated*(FRACTION[c.request] or 0));c.message=(free and "UNRESTRICTED" or "ASSISTED").." "..c.request.." output applied" end
end
local function draw(t,b,d,page,c,bs)
  local w,h=t.getSize();t.setBackgroundColor(colors.black);t.setTextColor(colors.white);t.clear();text(t,1,1,"HELIOS // DRACONIC GUARDIAN",colors.yellow)
  local banner=c.mode=="UNRESTRICTED" and "UNRESTRICTED CONTROL - AUTOMATIC INTERVENTION DISABLED" or c.mode=="ASSISTED" and "ASSISTED MANUAL - HARD SAFETY INTERLOCKS ACTIVE" or "AUTOMATIC SAFE SUPERVISION"
  text(t,1,2,banner,c.mode=="UNRESTRICTED" and colors.red or colors.lime);text(t,1,3,"[OVERVIEW] [RAW DATA] [SETUP] [MANUAL GATES]",colors.cyan)
  if not b.ready then text(t,1,5,"SETUP INVALID",colors.red);for i,v in ipairs(b.reasons) do text(t,1,5+i,"- "..v) end;return end
  if not d then text(t,1,5,"TELEMETRY LOST",colors.red);return end
  if page=="setup" then text(t,1,5,"FIXED GATE TOPOLOGY VALID",colors.lime);text(t,1,7,"Reactor component: "..b.reactor);text(t,1,8,"Export gate (LEFT/RIGHT): "..b.output);text(t,1,9,"Injector field gate (MODEM): "..b.input);text(t,1,10,"Wired modem: "..b.modem);text(t,1,12,"Export and containment roles are fixed; Guardian will not infer them.",colors.orange);return end
  if page=="raw" then text(t,1,5,"RAW DRACONIC TELEMETRY",colors.cyan);local ks={};for k in pairs(d.reactor) do ks[#ks+1]=tostring(k) end;sort(ks);for i,k in ipairs(ks) do if i+6<h then text(t,1,i+6,k..": "..tostring(d.reactor[k])) end end;return end
  if page=="gates" then
    text(t,1,5,"MANUAL GATES // unrestricted only",c.mode=="UNRESTRICTED" and colors.red or colors.orange)
    if c.mode~="UNRESTRICTED" then text(t,1,7,"Arm Unrestricted control before changing either gate manually.",colors.orange);return end
    text(t,1,7,"FIELD GATE (injector): "..fmt(c.manualField or d.inputSet).." RF/t",colors.cyan)
    bs[#bs+1]=button(t,1,9,"FIELD -1M",colors.cyan,1);bs[#bs+1]=button(t,16,9,"FIELD -100k",colors.cyan,1);bs[#bs+1]=button(t,34,9,"FIELD +100k",colors.cyan,1);bs[#bs+1]=button(t,53,9,"FIELD +1M",colors.cyan,1)
    text(t,1,12,"EXPORT GATE: "..fmt(c.manualExport or d.outputSet).." RF/t",colors.orange)
    bs[#bs+1]=button(t,1,14,"EXPORT -1M",colors.cyan,1);bs[#bs+1]=button(t,16,14,"EXPORT -100k",colors.cyan,1);bs[#bs+1]=button(t,34,14,"EXPORT +100k",colors.cyan,1);bs[#bs+1]=button(t,53,14,"EXPORT +1M",colors.cyan,1)
    bs[#bs+1]=button(t,1,17,"USE LIVE GATES",colors.lightGray,1);bs[#bs+1]=button(t,22,17,"APPLY MANUAL",colors.lime,1)
    bs[#bs+1]=button(t,1,20,"SAVE AS OVERDRIVE PRESET",colors.red,1);bs[#bs+1]=button(t,35,20,"BACK",colors.lightGray,1)
    text(t,1,23,"Overdrive keeps this field setting and ramps only export to the saved target.",colors.lightGray)
    return
  end
  local r=d.reactor;if w<54 or h<25 then text(t,1,5,"Large monitor required for the Guardian console.",colors.orange);text(t,1,7,"State: "..tostring(r.status).."  Temp: "..fmt(r.temperature).." C");text(t,1,8,"Generation: "..fmt(r.generationRate).." RF/t");return end
  -- Match the reactor GUI's composition: two bars, central telemetry, two
  -- bars. Every central line is clipped before the right-hand pair.
  local x,rightSat,rightFuel=18,w-11,w-5
  local centerWidth=math.max(12,rightSat-x-2)
  local function center(y,s,color) text(t,x,y,string.sub(tostring(s),1,centerWidth),color) end
  local function centerWrap(y,s,color,maxLines)
    local remaining=tostring(s or "")
    for line=1,(maxLines or 1) do
      if #remaining<=centerWidth then center(y+line-1,remaining,color);return end
      local chunk=string.sub(remaining,1,centerWidth)
      local split=chunk:match("^.*()%s") or centerWidth
      center(y+line-1,string.sub(remaining,1,split-1),color)
      remaining=string.gsub(string.sub(remaining,split+1),"^%s+","")
    end
  end
  vertical(t,2,5,12,"CORE",r.temperature,MAX_TEMPERATURE,colors.orange)
  vertical(t,9,5,12,"FIELD",r.fieldStrength,tonumber(r.maxFieldStrength),colors.red)
  vertical(t,rightSat,5,12,"SAT",r.energySaturation,tonumber(r.maxEnergySaturation),colors.blue)
  vertical(t,rightFuel,5,12,"FUEL",r.fuelConversion,tonumber(r.maxFuelConversion),colors.lime)
  center(5,"REACTOR TELEMETRY",colors.cyan);center(7,"State: "..tostring(r.status),colors.lime);center(8,"Generation: "..fmt(r.generationRate).." RF/t",colors.cyan)
  center(9,"Core temperature: "..fmt(r.temperature).." C",colors.orange);center(10,"Containment field strength: "..fmt(r.fieldStrength).." / "..fmt(r.maxFieldStrength));center(11,"Energy saturation: "..fmt(r.energySaturation).." / "..fmt(r.maxEnergySaturation));center(12,"Fuel conversion level: "..fmt(r.fuelConversion).." / "..fmt(r.maxFuelConversion))
  center(14,"GATE CONTROL",colors.cyan);center(15,"Field: "..fmt(d.inputFlow).." / "..fmt(d.inputSet),d.inputOverride and colors.lime or colors.red);center(16,"Export: "..fmt(d.outputFlow).." / "..fmt(d.outputSet),d.outputOverride and colors.lime or colors.red);center(17,"modem=field; "..tostring(b.output).."=export",colors.lightGray);centerWrap(18,"GUARDIAN: "..c.message,c.mode=="UNRESTRICTED" and colors.red or colors.lightGray,3)
  local y=h-7;if not c.gatesOwned then
    text(t,1,y-2,"GATE CONTROL NOT ACQUIRED - REACTOR START DISABLED",colors.red)
    text(t,1,y-1,"Guardian must show field override true and output override true.",colors.orange)
    if c.gateError then text(t,1,y,"API error: "..tostring(c.gateError),colors.red) end
    bs[#bs+1]=button(t,1,y+3,"SAFE SHUTDOWN",colors.red)
  elseif not c.commissioned then
    text(t,1,y-2,"OUTPUT SELECTOR  [OFF] [MIN] [MED] [MAX] [OVERDRIVE]",colors.gray)
    text(t,1,y-1,"LOCKED: calibrate a verified output ceiling against live containment.",colors.orange)
    bs[#bs+1]=button(t,1,y,"AUTO COMMISSION",colors.orange)
    text(t,1,y+1,"Starts at 50k RF/t; rises while the field stays at or above 17%.",colors.lightGray)
    bs[#bs+1]=button(t,1,y+3,"INITIALIZE & ACTIVATE",colors.lime)
    bs[#bs+1]=button(t,27,y+3,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="AUTO" then bs[#bs+1]=button(t,1,y,"ENABLE ASSISTED MANUAL",colors.orange);bs[#bs+1]=button(t,27,y,"RECALIBRATE CEILING",colors.orange);bs[#bs+1]=button(t,1,y+2,"INITIALIZE & ACTIVATE",colors.lime);bs[#bs+1]=button(t,27,y+2,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="ASSISTED" then
    local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX"}) do local q=button(t,px,y,v,colors.cyan);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,px,y,"ARM UNRESTRICTED",colors.red)
    bs[#bs+1]=button(t,1,y+2,"INITIALIZE & ACTIVATE",colors.lime);bs[#bs+1]=button(t,27,y+2,"SAFE SHUTDOWN",colors.red)
    bs[#bs+1]=button(t,1,y+4,"RESTORE AUTOMATIC",colors.lime);bs[#bs+1]=button(t,27,y+4,"RECALIBRATE CEILING",colors.orange)
  else local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX","OVERDRIVE"}) do local q=button(t,px,y,v,colors.red);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,1,y+2,"RESTORE AUTOMATIC",colors.lime) end
  if c.arm and c.arm>0 then local labels={"LIFT SAFETY INTERLOCK","DISABLE AUTOMATIC CONTROL","TURN AUTHORIZATION KEY","ARM UNRESTRICTED CONTROL"};text(t,1,h-3,"UNRESTRICTED ARMING "..c.arm.."/4: "..labels[c.arm],colors.red);bs[#bs+1]=button(t,1,h-2,labels[c.arm],colors.red);bs[#bs+1]=button(t,35,h-2,"CANCEL",colors.lightGray) end
end
local function drawComputer(t,d,c)
  local w,h=t.getSize();t.setBackgroundColor(colors.black);t.setTextColor(colors.white);t.clear()
  local function line(y,s,color)
    if y>h then return end
    t.setCursorPos(1,y);t.setTextColor(color or colors.white);t.write(string.sub(tostring(s or ""),1,w))
  end
  line(1,"HELIOS DRACONIC GUARDIAN // COMPUTER",colors.yellow)
  line(2,"Mode: "..tostring(c.mode).."  Request: "..tostring(c.request),c.mode=="UNRESTRICTED" and colors.red or colors.lime)
  if d and d.reactor then
    local r=d.reactor
    line(4,"State "..tostring(r.status).."  Gen "..fmt(r.generationRate).." RF/t",colors.cyan)
    line(5,"Core "..fmt(r.temperature).." C  Field "..string.format("%.1f%%",pct(r.fieldStrength,r.maxFieldStrength) or 0),colors.orange)
    line(6,"Saturation "..string.format("%.1f%%",pct(r.energySaturation,r.maxEnergySaturation) or 0).."  Fuel conversion "..string.format("%.1f%%",pct(r.fuelConversion,r.maxFuelConversion) or 0))
    line(7,"Field gate "..fmt(d.inputSet).."  Export gate "..fmt(d.outputSet),colors.lime)
  else line(4,"TELEMETRY LOST",colors.red) end
  line(9,"a start | s stop | c calibrate | r automatic")
  line(10,"m assisted | u arm/confirm unrestricted")
  line(11,"0 OFF | 1 MIN | 2 MED | 3 MAX | 4 OVERDRIVE")
  line(12,"Field: f/F -/+100k | v/V -/+1M")
  line(13,"Export: e/E -/+100k | x/X -/+1M")
  line(14,"p apply manual | o save Overdrive | q quit")
  line(16,"Manual field "..fmt(c.manualField or 0).."  export "..fmt(c.manualExport or 0),colors.cyan)
  line(17,"Guardian: "..tostring(c.message),colors.lightGray)
end
local binding,page,controls,buttons=inspect(),"overview",load(),{};local computer=term.current();local target=binding.monitor and peripheral.wrap(binding.monitor) or computer;compactMonitor(target,binding.monitor~=nil)
local function beginCalibration()
  controls.commissioning=true;controls.commissionFlow=COMMISSION_START_FLOW;controls.commissionSamples=0;controls.commissionShortfallSamples=0;controls.commissionSettleSamples=0;controls.commissionLastSafe=nil;controls.recovery=false;controls.commissioned=false;controls.rated=nil;controls.request="OFF"
  controls.initialRequested=true;controls.startActivated=false;controls.message="Automatic calibration requested by operator"
end
local function act(choice,d)
  if (choice=="AUTO COMMISSION" or choice=="RECALIBRATE CEILING") and controls.gatesOwned then beginCalibration()
  elseif choice=="INITIALIZE & ACTIVATE" and controls.gatesOwned then controls.initialRequested=true;controls.startActivated=false;controls.message="Initial start requested by operator"
  elseif choice=="SAFE SHUTDOWN" then controls.initialRequested=false;controls.startActivated=false;gate(binding.output,0);reactor(binding.reactor,"stopReactor");controls.message="Operator safe shutdown: output closed and stop sent"
  elseif choice=="ENABLE ASSISTED MANUAL" then controls.mode="ASSISTED";controls.request="OFF";controls.message="Assisted manual enabled at OFF"
  elseif choice=="ARM UNRESTRICTED" then controls.arm=1;controls.message="Unrestricted arming started"
  elseif choice=="CANCEL" then controls.arm=0;controls.message="Unrestricted arming cancelled"
  elseif controls.arm and controls.arm>0 and choice then controls.arm=controls.arm+1;if controls.arm>4 then controls.arm=0;controls.mode="UNRESTRICTED";controls.request="OFF";controls.message="UNRESTRICTED CONTROL ARMED: operator commands are not overridden" end
  elseif choice=="RESTORE AUTOMATIC" then controls.mode="AUTO";controls.request="OFF";controls.arm=0;controls.message="Automatic safety restored"
  elseif choice=="USE LIVE GATES" then controls.manualField=positive(d.inputSet) or positive(d.inputFlow) or controls.injectorBaseline;controls.manualExport=positive(d.outputSet) or positive(d.outputFlow) or 0;controls.message="Copied live gate limits into manual controls"
  elseif choice=="FIELD -100k" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_STEP)
  elseif choice=="FIELD +100k" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_STEP
  elseif choice=="FIELD -1M" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_LARGE_STEP)
  elseif choice=="FIELD +1M" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_LARGE_STEP
  elseif choice=="EXPORT -100k" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_STEP)
  elseif choice=="EXPORT +100k" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_STEP
  elseif choice=="EXPORT -1M" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_LARGE_STEP)
  elseif choice=="EXPORT +1M" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_LARGE_STEP
  elseif choice=="APPLY MANUAL" then controls.request="MANUAL";controls.overdriveApplied=0;controls.message="Manual gate pair requested"
  elseif choice=="SAVE AS OVERDRIVE PRESET" then
    local field=positive(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline
    local export=positive(controls.manualExport) or positive(d.outputSet)
    if field and export then controls.overdriveField=field;controls.overdriveExport=export;controls.message="Overdrive preset saved: field "..fmt(field)..", export "..fmt(export).." RF/t" else controls.message="Preset not saved: set positive field and export limits first" end
  elseif choice=="OVERDRIVE" then
    if positive(controls.overdriveField) and positive(controls.overdriveExport) then controls.request="OVERDRIVE";controls.overdriveApplied=0;controls.message="Saved Overdrive preset requested" else controls.message="No saved Overdrive preset: configure Manual Gates first" end
  elseif FRACTION[choice] then controls.request=choice;controls.message="Output request: "..choice end
end
local function keyboard(ch,d)
  local commands={a="INITIALIZE & ACTIVATE",s="SAFE SHUTDOWN",c="RECALIBRATE CEILING",r="RESTORE AUTOMATIC",m="ENABLE ASSISTED MANUAL",["0"]="OFF",["1"]="MIN",["2"]="MED",["3"]="MAX",["4"]="OVERDRIVE",f="FIELD -100k",F="FIELD +100k",v="FIELD -1M",V="FIELD +1M",e="EXPORT -100k",E="EXPORT +100k",x="EXPORT -1M",X="EXPORT +1M",p="APPLY MANUAL",o="SAVE AS OVERDRIVE PRESET"}
  local manualKey={f=true,F=true,v=true,V=true,e=true,E=true,x=true,X=true,p=true,o=true,["4"]=true}
  if manualKey[ch] and controls.mode~="UNRESTRICTED" then controls.message="Keyboard manual gates require Unrestricted mode";return end
  if ch=="u" then act((controls.arm or 0)>0 and "KEYBOARD CONFIRM" or "ARM UNRESTRICTED",d)
  elseif commands[ch] then act(commands[ch],d) end
end
-- Reactor supervision remains responsive at 10 Hz, while the expensive large
-- monitor redraw and settings write run at 2 Hz. Touch events are handled
-- continuously instead of competing with a redraw every tenth of a second.
local data=binding.ready and read(binding) or nil
if data then supervise(binding,data,controls);data=read(binding) or data end
local function redraw()
  buttons={}
  if target~=computer then draw(target,binding,data,page,controls,buttons) end
  drawComputer(computer,data,controls)
end
redraw()
local controlTimer=os.startTimer(.1)
local controlTicks=0
while true do
  local e,a,b,c=os.pullEvent()
  if e=="timer" and a==controlTimer then
    data=binding.ready and read(binding) or nil
    if data then supervise(binding,data,controls);data=read(binding) or data end
    controlTicks=controlTicks+1
    if controlTicks>=5 then controlTicks=0;save(controls);redraw() end
    controlTimer=os.startTimer(.1)
  elseif e=="char" then
    if a=="q" then save(controls);return end
    if data then keyboard(a,data);redraw() end
  elseif e=="key" then
    if a==keys.q then save(controls);return end
    if a==keys.one then page="overview" elseif a==keys.two then page="raw" elseif a==keys.three then page="setup" elseif a==keys.four then page="gates" end
    redraw()
  elseif e=="monitor_touch" and binding.monitor and a==binding.monitor then
    if c==3 then page=b<=10 and "overview" or b<=21 and "raw" or b<=29 and "setup" or "gates";redraw()
    else
      local choice=hit(buttons,b,c)
      if choice=="BACK" then page="overview";redraw()
      elseif choice then act(choice,data);redraw() end
    end
  elseif e=="peripheral" or e=="peripheral_detach" then
    binding=inspect();target=binding.monitor and peripheral.wrap(binding.monitor) or term.current();compactMonitor(target,binding.monitor~=nil);data=binding.ready and read(binding) or nil;redraw()
  end
end

