-- HELIOS Draconic Guardian v1.0
-- Dedicated local Draconic controller. Never install this on the normal
-- HELIOS modem bus: it owns exactly one reactor component and its two gates.

local FIELD_TARGET, FIELD_EMERGENCY = 50, 15
local MAX_TEMPERATURE, MINIMUM_FUEL = 8000, 10
local COMMISSION_FLOW, COMMISSION_SAMPLES = 50000, 20
local FRACTION = { OFF = 0, MIN = .25, MED = .50, MAX = 1, OVERDRIVE = 1.25 }
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
  local p, reactors, outputs, modems, monitors = localSides(), {}, {}, {}, {}
  for side in pairs(p) do
    if hasType(side, "draconic_reactor") then reactors[#reactors+1] = side end
    if hasType(side, "flow_gate") then outputs[#outputs+1] = side end
    if hasType(side, "modem") then modems[#modems+1] = side end
    if hasType(side, "monitor") then monitors[#monitors+1] = side end
  end
  local inputs = {}; for _, n in ipairs(peripheral.getNames()) do if not p[n] and hasType(n,"flow_gate") then inputs[#inputs+1]=n end end
  sort(reactors);sort(outputs);sort(modems);sort(monitors);sort(inputs)
  local why={}; if #reactors~=1 then why[#why+1]="Require exactly one local Draconic reactor component" end
  if #outputs~=1 then why[#why+1]="Require exactly one local output flow gate" end
  if #modems<1 then why[#why+1]="Require one local wired modem/peripheral hub" end
  if #inputs~=1 then why[#why+1]="Require exactly one remote field-input flow gate" end
  return {ready=#why==0,reasons=why,reactor=reactors[1],output=outputs[1],modem=modems[1],monitor=monitors[1],input=inputs[1]}
end
local function call(n,m,...)
  if not n then return nil,"missing" end
  local ok,v=pcall(peripheral.call,n,m,...); if not ok then return nil,tostring(v) end; return v
end
local function read(b)
  local r,e=call(b.reactor,"getReactorInfo"); if type(r)~="table" then return nil,e or "getReactorInfo failed" end
  return {reactor=r,inputFlow=call(b.input,"getFlow"),outputFlow=call(b.output,"getFlow"),inputSet=call(b.input,"getSignalLowFlow"),outputSet=call(b.output,"getSignalLowFlow"),inputOverride=call(b.input,"getOverrideEnabled"),outputOverride=call(b.output,"getOverrideEnabled")}
end
local function gate(n,v) return pcall(peripheral.call,n,"setSignalLowFlow",math.max(0,math.floor(tonumber(v) or 0))) end
local function reactor(n,m) return pcall(peripheral.call,n,m) end
local function pct(a,b) if tonumber(a) and tonumber(b) and tonumber(b)>0 then return tonumber(a)/tonumber(b)*100 end end
local function clamp(x) return math.max(0,math.min(1,tonumber(x) or 0)) end
local function fmt(n)
  n=tonumber(n);if not n then return "N/A" end;local u={"","k","M","B","T","Qa"};local i=1
  while math.abs(n)>=1000 and i<#u do n=n/1000;i=i+1 end
  return string.format(math.abs(n)>=100 and "%.0f%s" or "%.2f%s",n,u[i])
end
local function text(t,x,y,s,c) local w=select(1,t.getSize());if y>=1 then t.setCursorPos(x,y);t.setTextColor(c or colors.white);t.write(string.sub(tostring(s),1,math.max(0,w-x+1))) end end
local function button(t,x,y,label,c) local v="["..label.."]";text(t,x,y,v,c or colors.cyan);return {x1=x,x2=x+#v-1,y=y,label=label} end
local function hit(bs,x,y) for _,b in ipairs(bs) do if b.y==y and x>=b.x1 and x<=b.x2 then return b.label end end end
local function vertical(t,x,y,h,label,now,maximum,c)
  local f=maximum and clamp((tonumber(now) or 0)/maximum) or 0;text(t,x,y,label,colors.lightGray)
  for row=1,h do t.setCursorPos(x,y+row);t.setBackgroundColor(row>h-math.max(1,math.floor(h*f)) and c or colors.gray);t.write("    ") end
  t.setBackgroundColor(colors.black);text(t,x,y+h+1,string.format("%3.0f%%",f*100),c)
end
local function load()
  local d={mode="AUTO",request="OFF",rated=nil,commissioned=false,commissioning=false,commissionSamples=0,arm=0,initialRequested=false,startActivated=false,message="Automatic safe supervision"}
  if not fs.exists(SETTINGS) then return d end;local ok,s=pcall(dofile,SETTINGS);if not ok or type(s)~="table" then return d end
  d.mode=(s.mode=="ASSISTED" or s.mode=="UNRESTRICTED") and s.mode or "AUTO";d.request=FRACTION[s.request] and s.request or "OFF";d.rated=tonumber(s.rated);d.commissioned=s.commissioned==true;d.message=tostring(s.message or d.message);return d
end
local function save(c) local h=fs.open(SETTINGS,"w");if h then h.write("return "..textutils.serialize(c));h.close() end end

-- AUTO and ASSISTED retain containment. UNRESTRICTED is visibly armed and lets
-- the operator's command stand, while warnings remain live.
local function supervise(b,d,c)
  local r=d.reactor;local status=string.lower(tostring(r.status or "unknown"));local field=pct(r.fieldStrength,r.maxFieldStrength) or 0
  local fuel=pct((tonumber(r.maxFuelConversion) or 0)-(tonumber(r.fuelConversion) or 0),r.maxFuelConversion) or 0;local temp=tonumber(r.temperature) or math.huge;local free=c.mode=="UNRESTRICTED"
  local function stop(reason,charge) gate(b.output,0);reactor(b.reactor,"stopReactor");if charge then reactor(b.reactor,"chargeReactor");gate(b.input,900000) end;c.message="SAFETY INTERLOCK: "..reason;return true end
  if not free then
    if fuel<=MINIMUM_FUEL then return stop("fuel reserve below "..MINIMUM_FUEL.."%") end
    if status=="online" and field<=FIELD_EMERGENCY then return stop("field below "..FIELD_EMERGENCY.."%",true) end
    if temp>MAX_TEMPERATURE then return stop("temperature above "..MAX_TEMPERATURE.." C") end
  elseif fuel<=MINIMUM_FUEL or field<=FIELD_EMERGENCY or temp>MAX_TEMPERATURE then c.message="UNRESTRICTED WARNING: a containment/fuel/temperature limit is exceeded" end
  if status=="charging" then gate(b.input,900000);c.message="Charging containment";return end
  if c.initialRequested then
    if status=="offline" or status=="stopping" then
      reactor(b.reactor,"chargeReactor");gate(b.input,900000);c.message="Initial start: charging containment"
      return
    end
    if not c.startActivated and (status=="charged" or status=="warming_up" or status=="warning_up") then
      reactor(b.reactor,"activateReactor");gate(b.input,math.max(1,(tonumber(r.fieldDrainRate) or 0)/(1-FIELD_TARGET/100)))
      c.startActivated=true;c.message="Initial start: activation sent; waiting for ONLINE"
      return
    end
    if status=="online" then c.initialRequested=false;c.startActivated=false;c.message="Initial start complete; reactor is ONLINE" end
  end
  if c.commissioning then
    if status ~= "online" then
      c.initialRequested=true
      c.message="Automatic commissioning: waiting for reactor to reach ONLINE"
      return
    end
    gate(b.input,math.max(1,(tonumber(r.fieldDrainRate) or 0)/(1-FIELD_TARGET/100)))
    gate(b.output,COMMISSION_FLOW)
    local stable=field>=45 and temp<=6500 and fuel>MINIMUM_FUEL and (tonumber(d.outputFlow) or 0)>0
    c.commissionSamples=stable and (tonumber(c.commissionSamples) or 0)+1 or 0
    if c.commissionSamples>=COMMISSION_SAMPLES then
      c.rated=COMMISSION_FLOW;c.commissioned=true;c.commissioning=false;c.initialRequested=false
      c.message="Automatic commissioning complete: verified "..fmt(c.rated).." RF/t initial safe ceiling"
    else
      c.message="Automatic commissioning: stable sample "..c.commissionSamples.."/"..COMMISSION_SAMPLES
    end
    return
  end
  if c.mode=="AUTO" then if status=="online" then gate(b.input,math.max(1,(tonumber(r.fieldDrainRate) or 0)/(1-FIELD_TARGET/100))) end;c.message="Automatic: field held near "..FIELD_TARGET.."%; output awaits HELIOS request";return end
  if not c.commissioned or not c.rated then c.message="Control locked: run automatic commissioning first";return end
  if c.request=="OFF" then gate(b.output,0);reactor(b.reactor,"stopReactor");c.message="Manual OFF: export closed";return end
  if status=="offline" or status=="stopping" then reactor(b.reactor,"chargeReactor");gate(b.input,900000);c.message="Charging for requested output";return end
  if status=="charged" then reactor(b.reactor,"activateReactor");c.message="Starting for requested output";return end
  if status=="online" then gate(b.input,math.max(1,(tonumber(r.fieldDrainRate) or 0)/(1-FIELD_TARGET/100)));gate(b.output,c.rated*(FRACTION[c.request] or 0));c.message=(free and "UNRESTRICTED" or "ASSISTED").." "..c.request.." output applied" end
end
local function draw(t,b,d,page,c,bs)
  local w,h=t.getSize();t.setBackgroundColor(colors.black);t.setTextColor(colors.white);t.clear();text(t,1,1,"HELIOS // DRACONIC GUARDIAN",colors.yellow)
  local banner=c.mode=="UNRESTRICTED" and "UNRESTRICTED CONTROL - AUTOMATIC INTERVENTION DISABLED" or c.mode=="ASSISTED" and "ASSISTED MANUAL - HARD SAFETY INTERLOCKS ACTIVE" or "AUTOMATIC SAFE SUPERVISION"
  text(t,1,2,banner,c.mode=="UNRESTRICTED" and colors.red or colors.lime);text(t,1,3,"[OVERVIEW] [RAW DATA] [SETUP]",colors.cyan)
  if not b.ready then text(t,1,5,"SETUP INVALID",colors.red);for i,v in ipairs(b.reasons) do text(t,1,5+i,"- "..v) end;return end
  if not d then text(t,1,5,"TELEMETRY LOST",colors.red);return end
  if page=="setup" then text(t,1,5,"LOCAL SAFETY BOUNDARY VALID",colors.lime);text(t,1,7,"Reactor component: "..b.reactor);text(t,1,8,"Output gate:       "..b.output);text(t,1,9,"Field-input gate:  "..b.input);text(t,1,10,"Wired modem:       "..b.modem);text(t,1,12,"No normal HELIOS mainframe may control these peripherals.",colors.orange);return end
  if page=="raw" then text(t,1,5,"RAW DRACONIC TELEMETRY",colors.cyan);local ks={};for k in pairs(d.reactor) do ks[#ks+1]=tostring(k) end;sort(ks);for i,k in ipairs(ks) do if i+6<h then text(t,1,i+6,k..": "..tostring(d.reactor[k])) end end;return end
  local r=d.reactor;if w<54 or h<25 then text(t,1,5,"Large monitor required for the Guardian console.",colors.orange);text(t,1,7,"State: "..tostring(r.status).."  Temp: "..fmt(r.temperature).." C");text(t,1,8,"Generation: "..fmt(r.generationRate).." RF/t");return end
  vertical(t,2,5,12,"SAT",r.energySaturation,tonumber(r.maxEnergySaturation),colors.blue);vertical(t,8,5,12,"FIELD",r.fieldStrength,tonumber(r.maxFieldStrength),colors.red);vertical(t,16,5,12,"FUEL",(tonumber(r.maxFuelConversion) or 0)-(tonumber(r.fuelConversion) or 0),tonumber(r.maxFuelConversion),colors.lime);vertical(t,23,5,12,"OUT",d.outputFlow,math.max(1,tonumber(c.rated) or tonumber(d.outputSet) or 1),colors.orange)
  local x=31;text(t,x,5,"REACTOR TELEMETRY",colors.cyan);text(t,x,7,"State:       "..tostring(r.status),colors.lime);text(t,x,8,"Generation:  "..fmt(r.generationRate).." RF/t",colors.cyan);text(t,x,9,"Temperature: "..fmt(r.temperature).." C",colors.orange);text(t,x,10,"Field drain: "..fmt(r.fieldDrainRate).." RF/t");text(t,x,11,"Field input: "..fmt(d.inputFlow).." RF/t");text(t,x,12,"Output flow: "..fmt(d.outputFlow).." RF/t");text(t,x,13,"Output gate: "..fmt(d.outputSet).." RF/t");text(t,x,14,"Fuel burned: "..fmt(r.fuelConversion).." / "..fmt(r.maxFuelConversion));text(t,x,15,"Saturation:  "..fmt(r.energySaturation).." / "..fmt(r.maxEnergySaturation));text(t,x,17,"GUARDIAN: "..c.message,c.mode=="UNRESTRICTED" and colors.red or colors.lightGray)
  local y=h-7;if not c.commissioned then
    text(t,1,y-2,"OUTPUT SELECTOR  [OFF] [MIN] [MED] [MAX] [OVERDRIVE]",colors.gray)
    text(t,1,y-1,"LOCKED: run automatic commissioning to establish a verified safe ceiling.",colors.orange)
    bs[#bs+1]=button(t,1,y,"AUTO COMMISSION",colors.orange)
    text(t,1,y+1,"Starts safely, tests a conservative 50k RF/t export, and verifies containment.",colors.lightGray)
    bs[#bs+1]=button(t,1,y+3,"INITIALIZE & ACTIVATE",colors.lime)
    bs[#bs+1]=button(t,27,y+3,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="AUTO" then bs[#bs+1]=button(t,1,y,"ENABLE ASSISTED MANUAL",colors.orange);bs[#bs+1]=button(t,27,y,"ARM UNRESTRICTED",colors.red);bs[#bs+1]=button(t,1,y+2,"INITIALIZE & ACTIVATE",colors.lime);bs[#bs+1]=button(t,27,y+2,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="ASSISTED" then local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX"}) do local q=button(t,px,y,v,colors.cyan);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,px,y,"ARM UNRESTRICTED",colors.red);bs[#bs+1]=button(t,1,y+2,"RESTORE AUTOMATIC",colors.lime)
  else local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX","OVERDRIVE"}) do local q=button(t,px,y,v,colors.red);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,1,y+2,"RESTORE AUTOMATIC",colors.lime) end
  if c.arm and c.arm>0 then local labels={"LIFT SAFETY INTERLOCK","DISABLE AUTOMATIC CONTROL","TURN AUTHORIZATION KEY","ARM UNRESTRICTED CONTROL"};text(t,1,h-3,"UNRESTRICTED ARMING "..c.arm.."/4: "..labels[c.arm],colors.red);bs[#bs+1]=button(t,1,h-2,labels[c.arm],colors.red);bs[#bs+1]=button(t,35,h-2,"CANCEL",colors.lightGray) end
end
local binding,page,controls,buttons=inspect(),"overview",load(),{};local target=binding.monitor and peripheral.wrap(binding.monitor) or term.current()
local function act(choice,d)
  if choice=="AUTO COMMISSION" then controls.commissioning=true;controls.commissionSamples=0;controls.initialRequested=true;controls.startActivated=false;controls.message="Automatic commissioning requested by operator"
  elseif choice=="INITIALIZE & ACTIVATE" then controls.initialRequested=true;controls.startActivated=false;controls.message="Initial start requested by operator"
  elseif choice=="SAFE SHUTDOWN" then controls.initialRequested=false;controls.startActivated=false;gate(binding.output,0);reactor(binding.reactor,"stopReactor");controls.message="Operator safe shutdown: output closed and stop sent"
  elseif choice=="ENABLE ASSISTED MANUAL" then controls.mode="ASSISTED";controls.request="OFF";controls.message="Assisted manual enabled at OFF"
  elseif choice=="ARM UNRESTRICTED" then controls.arm=1;controls.message="Unrestricted arming started"
  elseif choice=="CANCEL" then controls.arm=0;controls.message="Unrestricted arming cancelled"
  elseif controls.arm and controls.arm>0 and choice then controls.arm=controls.arm+1;if controls.arm>4 then controls.arm=0;controls.mode="UNRESTRICTED";controls.request="OFF";controls.message="UNRESTRICTED CONTROL ARMED: operator commands are not overridden" end
  elseif choice=="RESTORE AUTOMATIC" then controls.mode="AUTO";controls.request="OFF";controls.arm=0;controls.message="Automatic safety restored"
  elseif FRACTION[choice] then controls.request=choice;controls.message="Output request: "..choice end;save(controls)
end
while true do
  local data=binding.ready and read(binding) or nil;if data then supervise(binding,data,controls);save(controls) end;buttons={};draw(target,binding,data,page,controls,buttons);local timer=os.startTimer(1)
  while true do local e,a,b,c=os.pullEvent();if e=="timer" and a==timer then break end;if e=="key" then if a==keys.q then return end;if a==keys.one then page="overview";break elseif a==keys.two then page="raw";break elseif a==keys.three then page="setup";break end elseif e=="monitor_touch" and target~=term.current() then if c==3 then page=b<=10 and "overview" or b<=21 and "raw" or "setup";break end;local choice=hit(buttons,b,c);if choice then act(choice,data);break end elseif e=="peripheral" or e=="peripheral_detach" then binding=inspect();target=binding.monitor and peripheral.wrap(binding.monitor) or term.current();break end end
end
