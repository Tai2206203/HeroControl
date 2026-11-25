-- Host-only contract test. All Unity/network interfaces are controlled stubs.
assert(dofile('Runtime/Payload/ComplaintHistory.lua')=='OK')
local describeReason=DoroCheatCheckToR9.describeReason
local prefs,loads,saves={},0,0
local monitor={enabled=false,records={},queryStatus='waiting_for_server',account='9007199254740993_1'}
monitor.describeReason=describeReason
monitor.formatTime=function(v) return tostring(v) end
monitor.status=function() return 'status' end
monitor.setEnabled=function(value) monitor.enabled=value end
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
 Assets={Scripts={Framework={GameDataMgr={heroSkinDatabin=bin}},GameSystem={
 CBattleSystem={instance={m_isInBattle=true}},MiniMapSysUT={Set3DUIWorldPos_ByScreenPoint=function(p)
   return {},100+2*p.x+p.z,200+p.x-3*p.z
 end}}}},
 UnityEngine={Screen={width=1000,height=500},Vector3=function(x,y,z) return {x=x,y=y,z=z} end,PlayerPrefs={
  SetInt=function(k,v) prefs[k]=v end,GetInt=function(k,d) if prefs[k]==nil then return d end;return prefs[k] end,
  SetFloat=function(k,v) prefs[k]=v end,GetFloat=function(k,d) return prefs[k] or d end,
  DeleteKey=function(k) prefs[k]=nil end,Save=function() saves=saves+1 end}}}
assert(dofile('Runtime/Runtime.lua')=='initialized')
local config={revision='revision-1',settings={flags={['reports.enabled']=true,['DoroCheat.Reference.R1.Icon']=true,
 ['DoroCheat.Reference.R1.Map']=true},cameraEnabled=true,cameraScale=1.75,selectedSkins={['123']=7}}}
local reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"phase":"active"',1,true),reply)
assert(reply:find('"source":"manual_overlay"',1,true),reply)
assert(reply:find('"required":false',1,true),reply)
assert(reply:find('"skins":false',1,true),reply)
assert(reply:find('"querySupported":true',1,true),reply)
assert(reply:find('"completeHistoryGuaranteed":false',1,true),reply)
assert(reply:find('"recordsTruncated":true',1,true),reply)
assert(reply:find('receipt:2050',1,true),reply)
assert(not reply:find('"id":"receipt:1"',1,true),reply)
assert(not reply:find('"records":{}',1,true),reply)
assert(prefs['DoroCheat.Reference.R2.CameraScale']==1) -- HUD owns camera, even when enabled.
assert(prefs['DoroCheat.Reference.R1.Icon']==0)
assert(prefs['DoroCheat.Reference.R1.Map']==0)
assert(prefs['DoroCheat.Style.SelectedSkin.123']==nil)
assert(prefs['DoroCheat.Style.Skin']==0)
assert(prefs['DoroCheat.Style.VerifiedSkin.123']==nil)
assert(loads==2 and saves==2)
HeroControlRuntimePulse(config,'/fixture');assert(loads==2 and saves==2)
config.revision='revision-2';config.settings.selectedSkins={};config.settings.cameraEnabled=false
config.settings.flags['reports.enabled']=false;monitor.records={}
reply=HeroControlRuntimePulse(config,'/fixture')
assert(prefs['DoroCheat.Style.SelectedSkin.123']==nil)
assert(prefs['DoroCheat.Reference.R2.CameraScale']==1)
assert(not monitor.enabled)
assert(reply:find('"records":[]',1,true),reply)
config.settings.flags['reports.enabled']=true
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"code":"reports_unknown"',1,true),reply)
assert(reply:find('"canConcludeNoReports":false',1,true),reply)
-- An absent reflected hero-name field must preserve usable numeric IDs.
HeroControlNativeRuntime.catalogReady=false
HeroControlNativeRuntime.catalog={}
local previousEnumerator=bin.GetEnumerator
function bin:GetEnumerator()
  local e=previousEnumerator(self)
  e.Current.Value=setmetatable({dwHeroID=599,dwSkinID=1,szSkinName='Skin'},
    {__index=function(_,key) error('missing reflected field: '..key) end})
  return e
end
reply=HeroControlRuntimePulse(config,'/fixture')
assert(not HeroControlNativeRuntime.catalogError,reply)
assert(#HeroControlNativeRuntime.catalog==1,reply)
assert(HeroControlNativeRuntime.catalog[1].id==599)
assert(HeroControlNativeRuntime.catalog[1].name=='')
config.settings=nil
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"phase":"failed"',1,true),reply)
print('Runtime Lua contract passed: patch loading once, preference readback, skin removal, camera opt-out, server metadata, bounded newest records and failure propagation; no game/network accessed.')

config.settings={flags={['reports.enabled']=true},selectedSkins={}}
ComplaintMonitorPolling.candidates={}
ComplaintMonitorPolling.captureError='player_center'
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"code":"reports_roster_error"',1,true),reply)
assert(reply:find('"candidateCaptureError":"player_center"',1,true),reply)
ComplaintMonitorPolling.captureError=''
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"code":"reports_waiting_roster"',1,true),reply)

monitor.records={{id='numeric-mail',event=1795580587,subject='Lịch sử bị tố cáo',reason='1',source='live'}}
reply=HeroControlRuntimePulse(config,'/fixture')
assert(reply:find('"reason":"Rớt mạng/AFK"',1,true),reply)
assert(reply:find('"reasonCode":1',1,true),reply)
