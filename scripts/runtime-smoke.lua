-- Host-only contract test. All Unity/network interfaces are controlled stubs.
assert(loadfile('Runtime/Payload/ComplaintHistory.lua'))
local prefs,loads,saves={},0,0
local monitor={enabled=false,records={},queryStatus='waiting_for_server',account='9007199254740993_1'}
monitor.formatTime=function(v) return tostring(v) end
monitor.status=function() return 'status' end
monitor.command=function(cmd) monitor.enabled=cmd=='/checkto on' end
monitor.tick=function() end
for i=1,2050 do monitor.records[i]={id='receipt:'..i,event=i,subject='notice',reason='reason',source='server_history'} end
_G.DoroCheatCheckToR9=monitor
_G.ComplaintMonitorRuntime={sentRequestCount=2,receivedResponseCount=1,transportFault=false}
_G.ComplaintMonitorPolling={candidates={{},{}}}
_G.N={}
local bin={Count=1}
function bin:GetEnumerator()
  local e={Current={Value={dwHeroID=123,dwSkinID=7,szHeroName='Hero',szSkinName='Skin'}}}
  local moved=false
  function e:MoveNext() if moved then return false end;moved=true;return true end
  function e:Dispose() end
  return e
end
CS={System={IO={File={ReadAllBytes=function() return {} end},MemoryStream=function() return {Dispose=function() end} end}},
 IFix={Core={PatchManager={Load=function() loads=loads+1;return {} end}}},
 Assets={Scripts={Framework={GameDataMgr={heroSkinDatabin=bin}}}},
 UnityEngine={PlayerPrefs={
  SetInt=function(k,v) prefs[k]=v end,GetInt=function(k,d) if prefs[k]==nil then return d end;return prefs[k] end,
  SetFloat=function(k,v) prefs[k]=v end,GetFloat=function(k,d) return prefs[k] or d end,
  DeleteKey=function(k) prefs[k]=nil end,Save=function() saves=saves+1 end}}}
assert(dofile('Runtime/Runtime.lua')=='initialized')
local config={revision='revision-1',settings={flags={['reports.enabled']=true,['DoroCheat.Reference.R1.Icon']=true,
 ['DoroCheat.Reference.R1.Map']=true},cameraEnabled=true,cameraScale=1.75,selectedSkins={['123']=7}}}
local reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"phase":"active"',1,true),reply)
assert(reply:find('"querySupported":true',1,true),reply)
assert(reply:find('"completeHistoryGuaranteed":false',1,true),reply)
assert(reply:find('"recordsTruncated":true',1,true),reply)
assert(reply:find('receipt:2050',1,true),reply)
assert(not reply:find('"id":"receipt:1"',1,true),reply)
assert(not reply:find('"records":{}',1,true),reply)
assert(prefs['DoroCheat.Reference.R2.CameraScale']==1.75)
assert(prefs['DoroCheat.Style.SelectedSkin.123']==7)
assert(prefs['DoroCheat.Style.VerifiedSkin.123']==nil)
assert(loads==2 and saves==1)
HeroControlRuntimePulse(config,'/fixture');assert(loads==2 and saves==1)
config.revision='revision-2';config.settings.selectedSkins={};config.settings.cameraEnabled=false
config.settings.flags['reports.enabled']=false;monitor.records={}
reply=HeroControlRuntimePulse(config,'/fixture')
assert(prefs['DoroCheat.Style.SelectedSkin.123']==nil)
assert(prefs['DoroCheat.Reference.R2.CameraScale']==1)
assert(not monitor.enabled)
assert(reply:find('"records":[]',1,true),reply)
config.settings=nil
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"phase":"failed"',1,true),reply)
print('Runtime Lua contract passed: patch loading once, preference readback, skin removal, camera opt-out, server metadata, bounded newest records and failure propagation; no game/network accessed.')
