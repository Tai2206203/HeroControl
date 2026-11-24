-- Executed by the bundled adapter on the game's main thread, never by the UI.
-- The two imported IFix payloads supply the original sprite/minimap/skin hooks.
local runtime = rawget(_G, 'HeroControlNativeRuntime')
if runtime then return 'already_initialized' end
runtime = {loaded={}, previousSkins={}, catalog={}, catalogReady=false}
rawset(_G, 'HeroControlNativeRuntime', runtime)

local function quote(s)
  return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
    return string.format('\\u%04x', string.byte(c))
  end) .. '"'
end
local function json(v)
  local t=type(v)
  if t=='nil' then return 'null' end
  if t=='boolean' then return v and 'true' or 'false' end
  if t=='number' then
    assert(v==v and v~=math.huge and v~=-math.huge, 'nonfinite_json')
    return tostring(v)
  end
  if t=='string' then return quote(v) end
  assert(t=='table', 'invalid_json_type')
  local out={}
  -- Empty lists are represented explicitly by their consumer below.
  if #v>0 then
    for i=1,#v do out[#out+1]=json(v[i]) end
    return '['..table.concat(out,',')..']'
  end
  for k,value in pairs(v) do out[#out+1]=quote(k)..':'..json(value) end
  return '{'..table.concat(out,',')..'}'
end
local function listJson(values)
  if #values==0 then return '[]' end
  return json(values)
end

local function readMinimapProjection()
  local ok,value=pcall(function()
    local battle=CS.Assets.Scripts.GameSystem.CBattleSystem.instance
    assert(battle and battle.m_isInBattle,'battle_not_ready')
    local width,height=tonumber(CS.UnityEngine.Screen.width),tonumber(CS.UnityEngine.Screen.height)
    assert(width and height and width>0 and height>0,'screen_not_ready')
    local function project(x,z)
      local _,sx,sy=CS.Assets.Scripts.GameSystem.MiniMapSysUT.Set3DUIWorldPos_ByScreenPoint(CS.UnityEngine.Vector3(x,0,z),true,0,0)
      sx,sy=tonumber(sx),tonumber(sy)
      assert(sx and sy and sx==sx and sy==sy and math.abs(sx)<1e8 and math.abs(sy)<1e8,'screen_projection_binding_unavailable')
      return sx/width,1-sy/height
    end
    local ox,oy=project(0,0)
    local xx,yx=project(16,0)
    local xz,yz=project(0,16)
    local checkX,checkY=project(16,16)
    assert(math.abs(checkX-(xx+xz-ox))<0.001 and math.abs(checkY-(yx+yz-oy))<0.001,'projection_not_affine')
    local a,b,c,d=(xx-ox)/16,(xz-ox)/16,(yx-oy)/16,(yz-oy)/16
    assert(math.abs(a*d-b*c)>1e-10,'projection_singular')
    return {available=true,source='game_screen_projection',ox=ox,oy=oy,xx=a,xz=b,yx=c,yz=d}
  end)
  if ok then return value end
  return {available=false,source='game_screen_projection',error=tostring(value)}
end

function HeroControlRuntimePulse(config, directory)
  local ok,result=pcall(function()
    if CS==nil or N==nil then
      return json({phase='waiting',code='runtime_waiting_bindings',message='Đang chờ bindings của game khởi tạo.'})
    end
    local IO=CS.System.IO
    -- Keep each VM alive. Loading is once per process/VM, not once per pulse.
    for _,name in ipairs({'HeroSkin_1.patch','HeroSkin_2.patch'}) do
      if not runtime.loaded[name] then
        local bytes=IO.File.ReadAllBytes(directory..'/'..name)
        local stream=IO.MemoryStream(bytes)
        local loaded,vm=pcall(function() return CS.IFix.Core.PatchManager.Load(stream,false) end)
        pcall(function() stream:Dispose() end)
        assert(loaded and vm~=nil, 'patch_load_failed:'..name..':'..tostring(vm))
        runtime.loaded[name]=vm
      end
    end
    local settings=assert(config.settings,'settings_missing')
    local prefs=CS.UnityEngine.PlayerPrefs
    for key,value in pairs(settings.flags) do
      if key~='reports.enabled' then
        -- ESP now belongs to the independent capture-protected HUD. Leave
        -- donor skins/camera/report hooks active without duplicate game ESP.
        local isEsp=key=='__ifxEnemyEspEnabledV1' or key:match('^DoroCheat%.Reference%.R1%.')
        local retired=key=='DoroCheat.Style.Buttons' or key=='DoroCheat.Style.Skin' or key=='DoroCheat.Style.BeforeMatch' or key=='DoroCheat.Style.LiveChange'
        local effective=not isEsp and not retired and value
        prefs.SetInt(key,effective and 1 or 0)
        assert(prefs.GetInt(key,-1)==(effective and 1 or 0),'flag_readback:'..key)
      end
    end
    local scale=settings.cameraEnabled and settings.cameraScale or 1.0
    prefs.SetFloat('DoroCheat.Reference.R2.CameraScale',scale)
    assert(math.abs(prefs.GetFloat('DoroCheat.Reference.R2.CameraScale',0)-scale)<0.0001,'camera_readback')
    -- Retired features are forced off even for a legacy profile.
    for _,key in ipairs({'Buttons','Skin','BeforeMatch','LiveChange'}) do prefs.SetInt('DoroCheat.Style.'..key,0) end
    for hero in pairs(settings.selectedSkins or {}) do
      prefs.DeleteKey('DoroCheat.Style.SelectedSkin.'..hero)
      prefs.DeleteKey('DoroCheat.Style.VerifiedSkin.'..hero)
    end
    runtime.previousSkins={}
    if runtime.savedRevision~=config.revision then prefs.Save();runtime.savedRevision=config.revision end

    local monitor=rawget(_G,'DoroCheatCheckToR9')
    if not monitor then
      local chunk,err=load(IO.File.ReadAllText(directory..'/ComplaintHistory.lua'),'HeroControlComplaintHistory')
      assert(chunk,err);assert(chunk()=='OK','complaint_bootstrap')
      monitor=assert(rawget(_G,'DoroCheatCheckToR9'),'complaint_missing')
    end
    if settings.flags['reports.enabled'] and not monitor.enabled then monitor.command('/checkto on') end
    if not settings.flags['reports.enabled'] and monitor.enabled then monitor.command('/checkto off') end
    if settings.flags['reports.enabled'] then
      if settings.reportsRefreshID and runtime.lastReportsRefresh~=settings.reportsRefreshID then
        local polling=rawget(_G,'ComplaintMonitorPolling')
        if polling then polling.cooldownTicks=0;polling.candidateIndex=1 end
        runtime.lastReportsRefresh=settings.reportsRefreshID
      end
      monitor.tick()
    end
    local records={}
    -- Export every retained receipt, rather than only today's last 50 rows.
    -- The ledger remains durable in the game's existing account-specific path.
    local retained=monitor.records or {}
    local recordBytes=0
    for index=#retained,math.max(1,#retained-2047),-1 do
      local r=retained[index]
      local record={id=tostring(r.id),time=monitor.formatTime(r.event),eventTime=tonumber(r.event),
        information=tostring(r.subject or ''),reason=tostring(r.reason or ''),source=r.source}
      local size=#json(record)
      if recordBytes+size>1024*1024 then break end
      recordBytes=recordBytes+size
      table.insert(records,1,record)
    end
    local transport=rawget(_G,'ComplaintMonitorRuntime') or {}
    local polling=rawget(_G,'ComplaintMonitorPolling') or {}
    local serverTime
    pcall(function() serverTime=tonumber(monitor.api.now()) end)
    if serverTime and (serverTime~=serverTime or math.abs(serverTime)==math.huge) then serverTime=nil end
    local reportCode='reports_disabled'
    local reportMessage='Truy vấn tố cáo đang tắt.'
    if settings.flags['reports.enabled'] then
      reportCode=#records>0 and 'reports_records_observed' or 'reports_unknown'
      reportMessage=(#records>0 and 'Đã có bản ghi được quan sát. ' or 'CHƯA XÁC ĐỊNH: chưa có bản ghi quan sát được; không kết luận không bị tố cáo. ')..tostring(monitor.queryStatus or monitor.status())
      if transport.transportFault then reportCode='reports_transport_fault' end
    end
    local reports={code=reportCode,
      message=reportMessage,source='server_history_and_mail',
      serverTime=serverTime,canConcludeNoReports=false,scope='known_player_history_and_delivered_mail',
      transportError=tostring(transport.errorMessage or ''),
      refreshID=runtime.lastReportsRefresh,
      querySupported=true,completeHistoryGuaranteed=false,
      accountID=monitor.account,sentRequestCount=transport.sentRequestCount or 0,
      receivedResponseCount=transport.receivedResponseCount or 0,
      candidateCount=#(polling.candidates or {}),transportFault=transport.transportFault or false,
      recordsTruncated=#retained>#records,
      retainedRecordCount=#(monitor.records or {}),
      serverResultCode=transport.lastResultCode}
    local reportJson=json(reports)
    reportJson=reportJson:sub(1,-2)..',"records":'..listJson(records)..'}'

    -- Read the same real databin used by donor VM_041, in bounded batches.
    -- Reflection failures are surfaced; no invented hero/skin catalogue.
    if not runtime.catalogReady then
      local catalogOK,catalogError=pcall(function()
        if not runtime.enumerator then
          local bin=CS.Assets.Scripts.Framework.GameDataMgr.heroSkinDatabin
          assert(bin and bin.Count>0 and bin.Count<=16384,'catalog_not_ready')
          runtime.enumerator=bin:GetEnumerator()
          runtime.byHero={}
        end
        for i=1,64 do
          if not runtime.enumerator:MoveNext() then
            pcall(function() runtime.enumerator:Dispose() end)
            runtime.enumerator=nil;runtime.catalogReady=true
            for _,hero in pairs(runtime.byHero) do
              table.sort(hero.skins,function(a,b) return a.id<b.id end)
              runtime.catalog[#runtime.catalog+1]=hero
            end
            table.sort(runtime.catalog,function(a,b) return a.id<b.id end)
            break
          end
          local entry=runtime.enumerator.Current.Value
          local heroID=tonumber(entry.dwHeroID)
          local skinID=tonumber(entry.dwSkinID)
          assert(heroID and skinID,'catalog_id_unavailable')
          local hero=runtime.byHero[heroID]
          if not hero then
            local heroName=''
            -- Optional reflection fields must not discard every known ID.
            pcall(function()
              local candidate=entry.szHeroName
              if candidate then heroName=tostring(candidate) end
            end)
            hero={id=heroID,name=heroName,skins={}}
            runtime.byHero[heroID]=hero
          end
          local name='Skin '..tostring(skinID)
          pcall(function()
            local candidate=entry.szSkinName
            if candidate and tostring(candidate)~='' then name=tostring(candidate) end
          end)
          runtime.catalogSeen=runtime.catalogSeen or {}
          local identity=tostring(heroID)..':'..tostring(skinID)
          if not runtime.catalogSeen[identity] then
            hero.skins[#hero.skins+1]={id=skinID,name=name}
            runtime.catalogSeen[identity]=true
          end
        end
      end)
      if not catalogOK then
        if runtime.enumerator then pcall(function() runtime.enumerator:Dispose() end) end
        runtime.enumerator=nil;runtime.byHero={};runtime.catalogSeen={};runtime.catalog={}
        runtime.catalogError=tostring(catalogError)
      else runtime.catalogError=nil end
    end
    if runtime.catalogReady and not runtime.skinPrefsCleared then
      for _,hero in ipairs(runtime.catalog) do
        prefs.DeleteKey('DoroCheat.Style.SelectedSkin.'..tostring(hero.id))
        prefs.DeleteKey('DoroCheat.Style.VerifiedSkin.'..tostring(hero.id))
      end
      prefs.Save();runtime.skinPrefsCleared=true
    end
    local state={minimapProjection=readMinimapProjection(),phase='active',code='runtime_configuration_readback',
      message='Runtime đã nạp hai patch và đọc lại cấu hình. Cần đối chiếu hình ảnh và phản hồi máy chủ.',
      appliedRevision=config.revision,acknowledgement='preferences_readback',
      effectsVerified=false,catalogError=runtime.catalogError,
      features={icon='bundled_hud_portrait',minimap='calibrated_hud_minimap',radar=false,
        skins=false,reports='server_available_per_known_player'}}
    local encoded=json(state)
    return encoded:sub(1,-2)..',"reports":'..reportJson..',"heroes":'..listJson(runtime.catalog)..'}'
  end)
  if ok then return result end
  return json({phase='failed',code='runtime_pulse_failed',message=tostring(result),effectsVerified=false})
end
return 'initialized'
