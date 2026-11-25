-- Local receipt ledger and Chap_To server-history monitoring for this account.
local globalKey = 'DoroCheatCheckToR9'
local existing = rawget(_G, globalKey)
if type(existing) == 'table' and existing.version == 25 then return 'OK' end

local m = {version=25, records={}, seen={}, pending=0, error='', account=nil,staleMail=setmetatable({},{__mode='k'})}
local floor = math.floor
local function clean(v)
  return tostring(v or ''):gsub('[\t\r\n%z]', ' '):sub(1, 2000)
end
function m.describeReason(value)
  if value==nil or tostring(value)=='' then return 'Máy chủ chưa cung cấp lý do chi tiết' end
  local code=tonumber(value)
  if not code then return clean(value) end
  local titles={[1]='Rớt mạng/AFK',[2]='Cố ý bị hạ',[3]='Chơi tiêu cực',[4]='Chửi bới/lăng mạ',
    [5]='Dàn xếp trận đấu',[6]='Dùng phần mềm gian lận',[7]='Rớt mạng/AFK',[14]='Chửi bới/lăng mạ',
    [20]='Trình độ chơi không phù hợp',[21]='Rời trận'}
  return titles[code] or ('Máy chủ trả mã lý do '..tostring(code)..'; chưa có mô tả chi tiết')
end

local function number(v)
  local n = tonumber(v)
  if not n or n ~= n or n < 0 or n > 4294967295 then return nil end
  return floor(n)
end
local function integer(n) return string.format('%.0f', n or 0) end

-- Bindings are kept together so the same shipped logic can run under controlled APIs.
m.api = {
  account=function()
    local r=N.CRoleInfoManager.instance:GetMasterRoleInfo()
    if not r then return nil end
    -- Never convert a 64-bit account identifier through a floating-point value.
    local uid=tostring(r.playerUllUID)
    local world=number(r.logicWorldID)
    if not uid:match('^%d+$') or uid=='0' or not world then return nil end
    return uid .. '_' .. integer(world)
  end,
  now=function() return tonumber(N.CRoleInfo.GetCurrentUTCTime()) end,
  clock=function() return CS.UnityEngine.Time.unscaledTime end,
  root=function() return CS.UnityEngine.Application.persistentDataPath .. '/vitduck_checkto' end,
  read=function(path)
    if not CS.System.IO.File.Exists(path) then return '' end
    return CS.System.IO.File.ReadAllText(path)
  end,
  append=function(path,text) CS.System.IO.File.AppendAllText(path,text) end,
  write=function(path,text) CS.System.IO.File.WriteAllText(path,text) end,
  mkdir=function(path) CS.System.IO.Directory.CreateDirectory(path) end,
  get=function(key,default) return CS.UnityEngine.PlayerPrefs.GetInt(key,default) end,
  set=function(key,value) CS.UnityEngine.PlayerPrefs.SetInt(key,value);CS.UnityEngine.PlayerPrefs.Save() end,
  battle=function()
    local battle=N.BattleLogic.instance
    return battle~=nil and battle.isRuning
  end,
  tip=function(text)
    N.OLDSYS_CUIManager.GetInstance():OpenTips(text,false,8,nil,nil)
    return true
  end,
  mail=function() return package.loaded['AOV.Mail.MailSys'] end,
  open=function() return N.CUICommonSystem.JumpFormLua(127,0,0,0,0) end,
}

local function key(suffix) return 'vitduck.CheckTo.R15.'..m.account..'.'..suffix end
local function leap(y) return y%4==0 and (y%100~=0 or y%400==0) end
local function calendar(epoch)
  local shifted=epoch+25200
  local absolute=floor(shifted/86400)
  local days=absolute
  local y=1970
  while days >= (leap(y) and 366 or 365) do days=days-(leap(y) and 366 or 365);y=y+1 end
  local lengths={31,leap(y) and 29 or 28,31,30,31,30,31,31,30,31,30,31}
  local month=1
  while days>=lengths[month] do days=days-lengths[month];month=month+1 end
  local seconds=shifted%86400
  return y,month,days+1,floor(seconds/3600),floor(seconds%3600/60),seconds%60,absolute
end
function m.formatTime(epoch)
  local y,mo,d,h,mi,s=calendar(epoch)
  return string.format('%04d-%02d-%02d %02d:%02d:%02d +07:00',y,mo,d,h,mi,s)
end
function m.bounds(period,now)
  local y,mo,d,h,mi,s,day=calendar(now)
  if period=='week' then day=day-((day+3)%7) -- Monday, fixed UTC+7.
  elseif period=='month' then day=day-d+1 end
  return day*86400-25200,now
end

local function fail(err) m.error=clean(err) end
local function loadLedger(text)
  for line in (text or ''):gmatch('([^\n]*)\n') do
    local f={}
    for value in (line..'\t'):gmatch('(.-)\t') do f[#f+1]=value end
    if #f==11 and f[1]=='R15' then
      local event,received=number(f[3]),number(f[4])
      if event and received and not m.seen[f[2]] then
        local r={id=f[2],event=event,received=received,basis=f[5],desk=f[6],seq=f[7],reason=f[8],warn=f[9],subject=f[10],source=f[11]}
        m.records[#m.records+1]=r;m.seen[r.id]=true
      end
    elseif line~='' then m.error='Có dòng nhật ký lỗi; dòng đó không được tính.' end
  end
end

local function quarantineOldMailbox()
  local ok,list=pcall(function()
    local mail=m.api.mail()
    return mail and mail.GetMailList and mail.GetMailList(M.COM_MAIL_SYSTEM)
  end)
  if ok and type(list)=='table' then for _,r in ipairs(list) do if type(r)=='table' then m.staleMail[r]=true end end end
end

function m.refresh()
  local account=m.api.account()
  if not account then
    if m.account then quarantineOldMailbox() end
    m.account=nil;m.records={};m.seen={};m.pending=0;m.enabled=false
    return false
  end
  if account~=m.account then
    if m.account then quarantineOldMailbox() end
    m.account=account;m.records={};m.seen={};m.pending=0;m.error=''
    m.dir=m.api.root()..'/'..account
    m.api.mkdir(m.dir)
    m.path=m.dir..'/received_reports.tsv'
    loadLedger(m.api.read(m.path))
    m.pending=m.api.get(key('Pending'),0)
  end
  m.enabled=m.api.get(key('Enabled'),0)==1
  m.since=m.api.get(key('Since'),0)
  return true
end

function m.observe(mailType,mail,source)
  if not m.refresh() or not m.enabled or type(mail)~='table' then return false end
  if m.staleMail[mail] then return false end
  -- Checked against target CMail.NewMailRes and MailSysFromView's own jump handler.
  local user=mail.userDataExtra
  if tonumber(mailType)~=tonumber(M.COM_MAIL_SYSTEM) or tonumber(mail.subType)~=tonumber(M.COM_MAIL_SYSTEM_BECOMPLAINT) then return false end
  if type(user)~='table' or tonumber(user.UserDataType)~=tonumber(M.COM_MAILUSER_DATA_HISTORY_BECOMPLAINT) then return false end
  local info=user.UserData and user.UserData.BeComplaintHistory
  if type(info)~='table' then return false end
  local index=number(mail.mailIndex)
  if not index then return false end
  local now=number(m.api.now())
  if not now then error('Chưa đọc được giờ máy chủ.') end
  local sent=number(mail.sendTime)
  local basis='server_mail_time'
  if not sent or sent==0 or sent>now+300 then sent=now;basis='first_received_time' end
  local id=integer(index)..':'..integer(sent)..':5'
  if m.seen[id] then return false end
  local r={id=id,event=sent,received=now,basis=basis,desk=integer(number(info.DeskID)),seq=integer(number(info.DeskSeq)),
    reason=clean(info.ChgCreditType),warn=clean(info.PassiveWarnCnt),subject=clean(mail.subject),source=source or 'mail'}
  local line=table.concat({'R15',r.id,integer(r.event),integer(r.received),r.basis,r.desk,r.seq,r.reason,r.warn,r.subject,r.source},'\t')..'\n'
  -- Persist before considering a receipt seen or notifying, so disk failures can retry.
  m.api.append(m.path,line)
  m.records[#m.records+1]=r;m.seen[id]=true
  if source~='cached' and now>=m.since then
    m.pending=m.pending+1;m.api.set(key('Pending'),m.pending)
    m.notify()
  end
  return true
end

function m.scan(source)
  local mail=m.api.mail()
  if type(mail)~='table' or type(mail.GetMailList)~='function' then return false end
  local list=mail.GetMailList(M.COM_MAIL_SYSTEM)
  if type(list)=='table' then
    for _,record in ipairs(list) do m.observe(M.COM_MAIL_SYSTEM,record,source) end
  end
  return true
end

function m.installMail()
  local mail=m.api.mail()
  if type(mail)~='table' or type(mail.AddMail)~='function' then return false end
  if mail.AddMail~=m.wrapper then
    local original=mail.AddMail
    m.wrapper=function(mailType,record,...)
      local values=table.pack(original(mailType,record,...))
      -- A monitoring failure must not alter native mail behavior or return values.
      local ok,err=pcall(m.observe,mailType,record,'live')
      if not ok then fail(err) end
      return table.unpack(values,1,values.n)
    end
    mail.AddMail=m.wrapper
  end
  return true
end

function m.notify()
  if m.pending<=0 or m.notifying or m.retired then return end
  local ok,err=pcall(function()
    if not m.refresh() or not m.enabled or m.api.battle() then return end
    m.notifying=true
    local count=m.pending
    if m.api.tip('ĐÃ NHẬN THÔNG BÁO BỊ TỐ CÁO: '..integer(count)..' bản ghi mới từ game. Xem lịch sử trong menu Hero Control.')~=false then
      m.pending=0;m.api.set(key('Pending'),0)
    end
  end)
  m.notifying=false
  if not ok then fail(err) end
end

function m.tick()
  local ok,err=pcall(function()
    if not m.refresh() or not m.enabled then return end
    -- Mail is optional: a broken/unready mailbox must not block history queries.
    m.queryPulse()
    local mailOK,mailError=pcall(function()
      m.mailReady=m.installMail()
      m.scan('poll')
    end)
    m.mailError=mailOK and '' or clean(mailError)
    m.notify()
  end)
  if not ok then fail(err) end
end

function m.list(period,now)
  local begin,finish=m.bounds(period,now)
  local rows={}
  for _,r in ipairs(m.records) do
    if r.event>=begin and r.event<=finish then rows[#rows+1]=r end
  end
  table.sort(rows,function(a,b) return a.event==b.event and a.id<b.id or a.event<b.event end)
  return rows
end

function m.status()
  if not m.refresh() then return 'Check tố: chờ đăng nhập.' end
  local now=number(m.api.now())
  if not now then return 'Chưa đọc được giờ máy chủ.' end
  local text='Check tố: '..(m.enabled and 'BẬT' or 'TẮT')..' | ngày='..integer(#m.list('day',now))
  text=text..' tuần='..integer(#m.list('week',now))..' tháng='..integer(#m.list('month',now))
  text=text..' | '..m.account..'\nChỉ tính thông báo game đã cung cấp và ghi nhận trên máy.'
  if not m.mailReady then text=text..'\nĐang chờ hệ thống thư của game.' end
  if m.error~='' then text=text..'\nLỗi gần nhất: '..m.error end
  text=text..'\nMáy chủ: '..(m.queryStatus or 'Chưa khởi tạo.')
  return text
end

function m.setEnabled(value)
  local ok,result=pcall(function()
    if not m.refresh() then return 'Chờ đăng nhập game.' end
    if value then
      local now=number(m.api.now())
      if not now then return 'Chưa đọc được giờ máy chủ.' end
      if not m.enabled then m.api.set(key('Since'),now) end
      m.api.set(key('Enabled'),1);m.enabled=true;m.since=m.api.get(key('Since'),now)
      if m.querySetEnabled then m.querySetEnabled(true) end
      m.queryPulse()
      local mailOK,mailError=pcall(function() m.mailReady=m.installMail();m.scan('cached') end)
      m.mailError=mailOK and '' or clean(mailError)
    else
      m.api.set(key('Enabled'),0);m.enabled=false;m.pending=0
      if m.querySetEnabled then m.querySetEnabled(false) end
      m.api.set(key('Pending'),0)
    end
    return m.status()
  end)
  if not ok then fail(result);return 'Lỗi bật/tắt theo dõi: '..m.error end
  return result
end

-- Retire the older observer if its mail wrapper is still in the current Lua VM.
-- It continues forwarding native mail; only the new observer records receipts.
if type(existing)=='table' then
  existing.retired=true;existing.observe=function() return false end
  if existing.stopQuery then pcall(existing.stopQuery) end
end
-- Chap_To's two embedded chunks run in a private lexical namespace. Their
-- transport wrapper keeps the game's history callbacks and FIFO waiters intact.
local function attachQueryMonitor(m)
  local ComplaintMonitorRuntime, ComplaintMonitorPolling
  local function installDonor()
local installationSucceeded, installationResult = pcall(function()

  local COMPLAINT_RESULT_NAMES = {
    [0]     = 'Succ',
    [93650] = 'Fail',
    [93651] = 'CntLimit',
    [93652] = 'Timeout',
    [93653] = 'OutOfGame',
    [93654] = 'NewbieProtect',
    [93703] = 'FailMarked',
  }

  local COMPLAINT_REASON_NAMES = {
    [1]='Guaji', [2]='Song', [3]='Xiaoji', [4]='Maren', [5]='Yanyuan',
    [6]='Gua', [7]='Hangup', [8]='NotLogin', [9]='Unconfirm',
    [10]='SettleDel', [11]='SettleAdd', [12]='OutGame', [13]='Recovery',
    [14]='Abuses', [15]='EvilPlayer', [16]='Butuan', [17]='XiaojiSelectHero',
    [18]='Qita', [19]='NotSelectAsPreselect', [20]='LowLevel', [21]='OutOfBattle',
    [22]='RecoveryReturnAcnt', [23]='RecoveryNewAcnt',
    [26]='EmailWarnPunish', [28]='XiaojiWarn', [29]='SystemMessEquip',
    [30]='MessEquip', [31]='UgcIllegal', [32]='RealtimeViolation',
  }

  -- IDs checked against this IPA's ResComplaintRule and dump constants.
  -- Use these only when the game's localization lookup fails.
  local COMPLAINT_REASON_VI = {
    [1]='Rớt mạng/AFK', [2]='Cố ý bị hạ',
    [3]='Cố ý không giao tranh tổng', [4]='Chửi bới lăng mạ',
    [5]='Buff bẩn', [6]='Dùng hack', [7]='Rớt mạng/AFK',
    [14]='Chửi bới lăng mạ', [19]='Cướp vị trí',
    [30]='Mua trang bị troll', [31]='Nội dung vi phạm',
  }

  local function readableTranslation(value, key)
    if type(value) ~= 'string' or not string.find(value, '%S') then return nil end
    if string.find(string.lower(value), 'notrans', 1, true) or
       string.match(value, '^%x+_?##$') or
       (#value == 16 and string.match(value, '^%x+$')) or value == key then return nil end
    return string.gsub(value, '[|\r\n]', ' ')
  end

  local function complaintReasonText(reasonIdentifier)
    local rule, translatedTitle
    pcall(function() rule = N.GameDataMgr.instance.resComplaintRule[reasonIdentifier] end)
    if rule ~= nil then
      pcall(function()
        local complaintSystem = package.loaded['AOV.Complaint.ComplaintSys']
        if complaintSystem and complaintSystem.GetComplaintTitle then
          translatedTitle = complaintSystem.GetComplaintTitle({reasonIdentifier}, 1)
        end
      end)
      local text = readableTranslation(translatedTitle, rule.ReportTitle)
      if text then return text end
      pcall(function() translatedTitle = T(rule.ReportTitle) end)
      text = readableTranslation(translatedTitle, rule.ReportTitle)
      if text then return text end
    end
    return COMPLAINT_REASON_VI[reasonIdentifier] or ('Mã lý do ' .. tostring(reasonIdentifier))
  end

  local function complaintReasonList(record)
    local reasonArray = record.ClientReasonArray or {}
    local count = tonumber(record.ClientReasonArrayNum) or #reasonArray
    count = math.max(0, math.min(math.floor(count), #reasonArray))
    local rawNames, titles, seen = {}, {}, {}
    for index = 1, count do
      local reasonIdentifier = tonumber(reasonArray[index])
      if reasonIdentifier and reasonIdentifier > 0 and not seen[reasonIdentifier] then
        seen[reasonIdentifier] = true
        local rawName = COMPLAINT_REASON_NAMES[reasonIdentifier]
        rawNames[#rawNames + 1] = rawName and
          (rawName .. '(' .. tostring(reasonIdentifier) .. ')') or tostring(reasonIdentifier)
        titles[#titles + 1] = complaintReasonText(reasonIdentifier)
      end
    end
    return #rawNames > 0 and table.concat(rawNames, ',') or 'None',
           #titles > 0 and table.concat(titles, ', ') or 'Máy chủ chưa cung cấp lý do chi tiết'
  end

  local function formatValueName(namesByIdentifier, identifier)
    if identifier == nil then return 'nil' end
    local valueName = namesByIdentifier[identifier]
    if valueName then return valueName .. '(' .. identifier .. ')' end
    return tostring(identifier)
  end

  if ComplaintMonitorRuntime == nil then
    ComplaintMonitorRuntime = {
      pendingRecords = {},
      pendingReporterIdentifier = 0,
      accountIdentifier = 0,
      accountWorldIdentifier = 0,
      sentRequestCount = 0,
      receivedResponseCount = 0,
      errorMessage = '',
      gameReportPauseCount = 0,
      accountGeneration = 0,
    }
  end

  function ComplaintMonitorRuntime.resetForAccount(accountIdentifier, worldIdentifier)
    ComplaintMonitorRuntime.accountGeneration = (ComplaintMonitorRuntime.accountGeneration or 0) + 1
    ComplaintMonitorRuntime.previousAccountIdentifier = ComplaintMonitorRuntime.accountIdentifier
    ComplaintMonitorRuntime.accountIdentifier = accountIdentifier
    ComplaintMonitorRuntime.accountWorldIdentifier = worldIdentifier
    ComplaintMonitorRuntime.pendingRecords = {}
    ComplaintMonitorRuntime.pendingReporterIdentifier = 0
    ComplaintMonitorRuntime.activeReporterIdentifier = 0
    ComplaintMonitorRuntime.sentRequestCount = 0
    ComplaintMonitorRuntime.receivedResponseCount = 0
    ComplaintMonitorRuntime.errorMessage = ''
    ComplaintMonitorRuntime.gameReportPauseCount = 0
    ComplaintMonitorRuntime.pendingRequestPollCount = 0
    ComplaintMonitorRuntime.pendingResponsePollCount = 0
    ComplaintMonitorRuntime.activeRequest = nil
    ComplaintMonitorRuntime.transportFault = false
    ComplaintMonitorRuntime.lastResultCode = nil
  end

  function ComplaintMonitorRuntime.refreshAccount()
    local accountLookupSucceeded, accountIdentifier, worldIdentifier = pcall(function()
      local roleInformation = N.CRoleInfoManager.instance:GetMasterRoleInfo()
      if roleInformation ~= nil then
        return roleInformation.playerUllUID, roleInformation.logicWorldID
      end
    end)
    if not accountLookupSucceeded then ComplaintMonitorRuntime.errorMessage = 'vai' end
    if not accountLookupSucceeded or accountIdentifier == nil or accountIdentifier == 0 then
      return false
    end
    if ComplaintMonitorRuntime.accountIdentifier == 0 then
      ComplaintMonitorRuntime.accountIdentifier = accountIdentifier
      ComplaintMonitorRuntime.accountWorldIdentifier = worldIdentifier
      return true, false, 0, accountIdentifier
    end
    if not ComplaintMonitorRuntime.identifiersMatch(ComplaintMonitorRuntime.accountIdentifier, accountIdentifier) or
       ComplaintMonitorRuntime.accountWorldIdentifier ~= worldIdentifier then
      local previousAccountIdentifier = ComplaintMonitorRuntime.accountIdentifier
      ComplaintMonitorRuntime.resetForAccount(accountIdentifier, worldIdentifier)
      return true, true, previousAccountIdentifier, accountIdentifier
    end
    ComplaintMonitorRuntime.accountWorldIdentifier = worldIdentifier
    return true, false, ComplaintMonitorRuntime.accountIdentifier, accountIdentifier
  end

  function ComplaintMonitorRuntime.identifierText(identifier)
    -- The shipped VM is Lua 5.3: preserve its 64-bit integers (%.0f loses bits).
    if type(identifier) == 'number' and math.type and math.type(identifier) == 'float' then
      return string.format('%.0f', identifier)
    end
    return tostring(identifier or 0)
  end

  function ComplaintMonitorRuntime.identifiersMatch(firstIdentifier, secondIdentifier)
    return ComplaintMonitorRuntime.identifierText(firstIdentifier) ==
           ComplaintMonitorRuntime.identifierText(secondIdentifier)
  end

  function ComplaintMonitorRuntime.collectComplaintRecords(responseMessage, reporterIdentifier, baselineOnly)
    local response = responseMessage.PkgData.ComplaintRecordRsp
    if response == nil then return end

    local resultInformation = response.ResultInfo
    if resultInformation ~= nil and resultInformation.ResultId ~= nil and resultInformation.ResultId ~= 0 then
      ComplaintMonitorRuntime.lastResultCode = resultInformation.ResultId
      ComplaintMonitorRuntime.errorMessage = 'rs' .. tostring(resultInformation.ResultId)
      if ComplaintMonitorPolling then ComplaintMonitorPolling.cooldownTicks = 40 end
      return
    end
    ComplaintMonitorRuntime.lastResultCode = nil

    local complaintRecords = response.RecordList
    if complaintRecords == nil then return end

    for recordIndex, complaintRecord in ipairs(complaintRecords) do
      if complaintRecord.BeComplaintUid ~= nil and
         ComplaintMonitorRuntime.identifiersMatch(complaintRecord.BeComplaintUid, ComplaintMonitorRuntime.accountIdentifier) then

        local rawReasonNames, displayReasons = complaintReasonList(complaintRecord)

        local gameStartTime = 0
        if complaintRecord.GameBriefInfo ~= nil and complaintRecord.GameBriefInfo.GameStartTime ~= nil then
          gameStartTime = complaintRecord.GameBriefInfo.GameStartTime
        end

        local maximumCheatCount, creditChangeType = 0, 0
        pcall(function()
          local complaintTypeValues = complaintRecord.ComplainTypeValueList
          if complaintTypeValues ~= nil then
            for valueIndex, complaintTypeValue in ipairs(complaintTypeValues) do
              local cheatCount = complaintTypeValue.BeComplaintCheatCount or 0
              if cheatCount > maximumCheatCount then maximumCheatCount = cheatCount end
              local currentCreditChangeType = complaintTypeValue.ChgCreditType or 0
              if currentCreditChangeType ~= 0 then creditChangeType = currentCreditChangeType end
            end
          end
        end)

        ComplaintMonitorRuntime.pendingRecords[#ComplaintMonitorRuntime.pendingRecords + 1] =
          string.format('%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s',
            baselineOnly and 'B' or 'R',
            ComplaintMonitorRuntime.identifierText(reporterIdentifier),
            ComplaintMonitorRuntime.identifierText(complaintRecord.BeComplaintUid),
            ComplaintMonitorRuntime.identifierText(ComplaintMonitorRuntime.accountIdentifier),
            tostring(gameStartTime),
            rawReasonNames,
            tostring(complaintRecord.DelCreditValue or 0),
            tostring(complaintRecord.DelBehaviorValue or 0),
            formatValueName(COMPLAINT_RESULT_NAMES, complaintRecord.Result),
            tostring(maximumCheatCount),
            tostring(complaintRecord.LeftCreditValue or 0),
            tostring(complaintRecord.PassiveEmailWarnCnt or 0),
            formatValueName(COMPLAINT_REASON_NAMES, creditChangeType),
            displayReasons)
      end
    end
  end

  function ComplaintMonitorRuntime.forwardGameResponse(responseMessage, requestMessage)
    ComplaintMonitorRuntime.trackedGameRequests[requestMessage] = nil
    local network = N.NetworkModule.instance
    local handler = network.registeredHandlers[M.CSID_CMD_COMPLAINT_RECORD_RSP]
    if handler then return handler(responseMessage, requestMessage) end
  end

  function ComplaintMonitorRuntime.ensureNetworkWrapper()
    local network = N.NetworkModule.instance
    local networkClass = package.loaded['AOV.CSExtension.NetworkModule']
    if networkClass == nil or type(networkClass.SendLobbyMsg) ~= 'function' or
       type(network.pendingReqInfoList) ~= 'table' then
      error('network_wrapper_missing')
    end
    -- Logout replaces this table in the real NetworkModule. Reset only then;
    -- a late reply after a timeout cannot safely identify its reporter.
    if ComplaintMonitorRuntime.networkQueue ~= network.pendingReqInfoList then
      ComplaintMonitorRuntime.networkQueue = network.pendingReqInfoList
      ComplaintMonitorRuntime.trackedGameRequests = {}
      ComplaintMonitorRuntime.activeRequest = nil
      ComplaintMonitorRuntime.pendingReporterIdentifier = 0
      ComplaintMonitorRuntime.transportFault = false
    end
    if networkClass.SendLobbyMsg ~= ComplaintMonitorRuntime.sendWrapper then
      ComplaintMonitorRuntime.originalSendLobbyMsg = networkClass.SendLobbyMsg
      ComplaintMonitorRuntime.sendWrapper = function(self, packet, showAlert, responseId, handler)
        -- The game's profile/history query normally sends with two arguments.
        -- Give only that same protocol a FIFO waiter too, so its reply cannot
        -- be consumed by the monitor's callback. Preserve its registered handler.
        local gameQuery = packet and packet.PkgHead and
          packet.PkgHead.MsgID == M.CSID_CMD_COMPLAINT_RECORD_REQ and responseId == nil
        if gameQuery then
          responseId = M.CSID_CMD_COMPLAINT_RECORD_RSP
          handler = ComplaintMonitorRuntime.forwardGameResponse
        end
        local sent = ComplaintMonitorRuntime.originalSendLobbyMsg(
          self, packet, showAlert, responseId, handler)
        if gameQuery and sent == true then
          ComplaintMonitorRuntime.trackedGameRequests[packet] = true
        end
        return sent
      end
      networkClass.SendLobbyMsg = ComplaintMonitorRuntime.sendWrapper
    end
    return network
  end

  function ComplaintMonitorRuntime.syncPendingRequest(network)
    local queue = network.pendingReqInfoList[M.CSID_CMD_COMPLAINT_RECORD_RSP] or {}
    local present = {}
    for _, info in ipairs(queue) do present[info.req] = true end
    local active = ComplaintMonitorRuntime.activeRequest
    if active ~= nil and not present[active] then
      ComplaintMonitorRuntime.activeRequest = nil
      ComplaintMonitorRuntime.pendingReporterIdentifier = 0
      ComplaintMonitorRuntime.transportFault = true
      ComplaintMonitorRuntime.errorMessage = 'timeout_relogin'
    end
    for packet in pairs(ComplaintMonitorRuntime.trackedGameRequests) do
      if not present[packet] then
        ComplaintMonitorRuntime.trackedGameRequests[packet] = nil
        ComplaintMonitorRuntime.transportFault = true
        ComplaintMonitorRuntime.errorMessage = 'timeout_relogin'
      end
    end
    return #queue > 0
  end

  function ComplaintMonitorRuntime.handleComplaintResponse(responseMessage, requestMessage, requestedReporter, baselineOnly)
    if requestMessage ~= ComplaintMonitorRuntime.activeRequest then return end
    ComplaintMonitorRuntime.activeRequest = nil
    ComplaintMonitorRuntime.pendingReporterIdentifier = 0
    ComplaintMonitorRuntime.receivedResponseCount = ComplaintMonitorRuntime.receivedResponseCount + 1

    if ComplaintMonitorRuntime.transportFault then return end

    local reporterIdentifier = nil
    pcall(function()
      reporterIdentifier = requestMessage.PkgData.ComplaintRecordReq.Uid
    end)
    if reporterIdentifier == nil then
      reporterIdentifier = requestedReporter
    end

    local recordReadSucceeded, recordReadError =
      pcall(ComplaintMonitorRuntime.collectComplaintRecords, responseMessage, reporterIdentifier, baselineOnly)
    if not recordReadSucceeded then
      ComplaintMonitorRuntime.errorMessage = 'doc:' .. tostring(recordReadError)
    else
      local response = responseMessage.PkgData.ComplaintRecordRsp
      local resultInfo = response and response.ResultInfo
      if response ~= nil and response.RecordList ~= nil and
         (resultInfo == nil or resultInfo.ResultId == nil or resultInfo.ResultId == 0) and
         ComplaintMonitorPolling ~= nil then
        for _, candidate in ipairs(ComplaintMonitorPolling.candidates) do
          if ComplaintMonitorRuntime.identifiersMatch(candidate.userIdentifier, reporterIdentifier) then
            candidate.baselineComplete = true
            break
          end
        end
      end
    end
  end

  function ComplaintMonitorRuntime.requestComplaintHistory(reporterIdentifier, worldIdentifier, baselineOnly)
    local accountReady, accountChanged = ComplaintMonitorRuntime.refreshAccount()
    if not accountReady then return '0' end
    if accountChanged then return '4' end
    local requestGeneration = ComplaintMonitorRuntime.accountGeneration or 0
    local requestSucceeded, requestStatus = pcall(function()
      local networkModule = ComplaintMonitorRuntime.ensureNetworkWrapper()
      local busy = ComplaintMonitorRuntime.syncPendingRequest(networkModule)
      if ComplaintMonitorRuntime.transportFault then return '5' end
      if busy then return '3' end
      local requestFields = {
        ComplaintRecordReq = { Uid = reporterIdentifier, LogicWorldID = worldIdentifier }
      }
      local requestPacket = networkModule:CreateDefaultCSPKG(M.CSID_CMD_COMPLAINT_RECORD_REQ, requestFields)
      ComplaintMonitorRuntime.pendingReporterIdentifier = reporterIdentifier
      ComplaintMonitorRuntime.activeReporterIdentifier = reporterIdentifier
      ComplaintMonitorRuntime.activeRequest = requestPacket
      local sent = networkModule:SendLobbyMsg(requestPacket, false, M.CSID_CMD_COMPLAINT_RECORD_RSP,
        function(responseMessage, requestMessage)
          if requestGeneration ~= ComplaintMonitorRuntime.accountGeneration then return end
          ComplaintMonitorRuntime.handleComplaintResponse(responseMessage, requestMessage, reporterIdentifier, baselineOnly)
        end)
      if sent ~= true then
        ComplaintMonitorRuntime.activeRequest = nil
        ComplaintMonitorRuntime.pendingReporterIdentifier = 0
        ComplaintMonitorRuntime.errorMessage = 'send_rejected'
        return '0'
      end
      ComplaintMonitorRuntime.sentRequestCount = ComplaintMonitorRuntime.sentRequestCount + 1
      return '1'
    end)

    if not requestSucceeded then
      ComplaintMonitorRuntime.activeRequest = nil
      ComplaintMonitorRuntime.pendingReporterIdentifier = 0
      ComplaintMonitorRuntime.errorMessage = 'send:' .. tostring(requestStatus)
      return '0'
    end
    return requestStatus
  end

  function ComplaintMonitorRuntime.takePendingRecords()
    pcall(function()
      ComplaintMonitorRuntime.syncPendingRequest(ComplaintMonitorRuntime.ensureNetworkWrapper())
    end)

    if #ComplaintMonitorRuntime.pendingRecords == 0 then
      local status = string.format('#|%d|%d|%s|%s',
        ComplaintMonitorRuntime.sentRequestCount,
        ComplaintMonitorRuntime.receivedResponseCount,
        tostring(ComplaintMonitorRuntime.pendingReporterIdentifier),
        ComplaintMonitorRuntime.errorMessage)
      ComplaintMonitorRuntime.errorMessage = ''
      return status
    end

    local records = table.concat(ComplaintMonitorRuntime.pendingRecords, '\n')
    ComplaintMonitorRuntime.pendingRecords = {}
    return records
  end

  return 'OK'
end)

if installationSucceeded then return installationResult end
return 'E:' .. tostring(installationResult)

  end
  local function pollDonor()
return (function()
if ComplaintMonitorRuntime == nil or
   ComplaintMonitorRuntime.requestComplaintHistory == nil or
   ComplaintMonitorRuntime.takePendingRecords == nil then
    return 'E:soito_missing'
end

if ComplaintMonitorPolling == nil then
    ComplaintMonitorPolling = {
        candidates = {},
        candidatesByIdentifier = {},
        candidateIndex = 1,
        cooldownTicks = 0,
        captureError = '',
        buildingBaseline = true,
        captureSequence = 0,
    }
end

local pollingState = ComplaintMonitorPolling
if pollingState.buildingBaseline == nil then pollingState.buildingBaseline = true end
if pollingState.captureSequence == nil then pollingState.captureSequence = 0 end
local MAX_RECENT_PLAYERS = 36

local function sanitizeText(value)
    local text = tostring(value or '')
    return string.gsub(text, '[|\r\n]', ' ')
end

local function formatUserIdentifier(value)
    return ComplaintMonitorRuntime.identifierText(value)
end

local accountReady, accountChanged, previousAccountIdentifier, currentAccountIdentifier =
    ComplaintMonitorRuntime.refreshAccount()
if not accountReady then return '#|soito|account_pending' end
if pollingState.accountGeneration == nil then
    pollingState.accountGeneration = ComplaintMonitorRuntime.accountGeneration or 0
end
if accountChanged or
   pollingState.accountGeneration ~= (ComplaintMonitorRuntime.accountGeneration or 0) then
    pollingState.candidates = {}
    pollingState.candidatesByIdentifier = {}
    pollingState.candidateIndex = 1
    pollingState.cooldownTicks = 0
    pollingState.captureError = ''
    pollingState.buildingBaseline = true
    pollingState.captureSequence = 0
    pollingState.accountGeneration = ComplaintMonitorRuntime.accountGeneration or 0
    return '#|soito|account_changed|old=' ..
        formatUserIdentifier(accountChanged and previousAccountIdentifier or
                             ComplaintMonitorRuntime.previousAccountIdentifier) ..
        '|new=' .. formatUserIdentifier(currentAccountIdentifier)
end

local function captureCandidates()
    local captureSucceeded, captureError = pcall(function()
        local playerCenter = CS.Kyrios.KyriosFramework.playerCenter
        if playerCenter == nil then error('player_center') end
        local allPlayers = playerCenter:GetAllPlayers()
        if allPlayers == nil then error('player_list') end
        local playerCount = tonumber(allPlayers.Count)
        if playerCount == nil or playerCount < 0 or playerCount > 32 then error('player_count') end
        pollingState.rosterPlayerCount=playerCount
        -- Stage a complete snapshot before mutating the cache: game objects can
        -- disappear during loading, and a failed read must not partially append.
        local capturedPlayers, capturedByIdentifier = {}, {}
        for playerIndex = 0, playerCount - 1 do
            local player = allPlayers[playerIndex]
            if player ~= nil and not player.Computer then
                local userIdentifier = player.PlayerUId
                local worldIdentifier = tonumber(player.LogicWrold) or 0
                if userIdentifier ~= nil and userIdentifier ~= 0 and worldIdentifier > 0 and
                   not ComplaintMonitorRuntime.identifiersMatch(userIdentifier, currentAccountIdentifier) then
                    local identifierKey = formatUserIdentifier(userIdentifier)
                    local captured = capturedByIdentifier[identifierKey]
                    if captured == nil then
                        captured = { identifierKey = identifierKey, userIdentifier = userIdentifier }
                        capturedByIdentifier[identifierKey] = captured
                        capturedPlayers[#capturedPlayers + 1] = captured
                    end
                    captured.playerName = sanitizeText(player.Name)
                    captured.worldIdentifier = worldIdentifier
                end
            end
        end
        pollingState.rosterEligibleCount=#capturedPlayers
        pollingState.captureSequence = pollingState.captureSequence + 1
        local currentByIdentifier = {}
        for _, captured in ipairs(capturedPlayers) do
            local key = captured.identifierKey
            local candidate = pollingState.candidatesByIdentifier[key]
            if candidate == nil then
                candidate = { userIdentifier = captured.userIdentifier, baselineComplete = false }
                pollingState.candidatesByIdentifier[key] = candidate
                pollingState.candidates[#pollingState.candidates + 1] = candidate
            end
            candidate.playerName = captured.playerName
            candidate.worldIdentifier = captured.worldIdentifier
            candidate.lastSeenCapture = pollingState.captureSequence
            currentByIdentifier[key] = true
        end
        -- Keep recent opponents/allies across matches, including their baseline.
        -- A partial/loading roster must not replace the last match's candidates.
        -- Bound memory and scan length; keep every current player and the waiter
        -- being attributed until its response has been consumed.
        local pendingReporter = ComplaintMonitorRuntime.pendingReporterIdentifier or 0
        local protectedReporter = pendingReporter ~= 0 and formatUserIdentifier(pendingReporter) or nil
        while #pollingState.candidates > MAX_RECENT_PLAYERS do
            local oldestIndex, oldestCapture = nil, nil
            for index, candidate in ipairs(pollingState.candidates) do
                local key = formatUserIdentifier(candidate.userIdentifier)
                local seenAt = candidate.lastSeenCapture or 0
                if not currentByIdentifier[key] and key ~= protectedReporter and
                   (oldestIndex == nil or seenAt < oldestCapture) then
                    oldestIndex, oldestCapture = index, seenAt
                end
            end
            -- Count is at most 32 current players plus one protected waiter.
            if oldestIndex == nil then break end
            local removed = table.remove(pollingState.candidates, oldestIndex)
            pollingState.candidatesByIdentifier[formatUserIdentifier(removed.userIdentifier)] = nil
            if oldestIndex < pollingState.candidateIndex then
                pollingState.candidateIndex = pollingState.candidateIndex - 1
            end
        end
        if pollingState.candidateIndex < 1 or pollingState.candidateIndex > #pollingState.candidates then
            pollingState.candidateIndex = 1
        end
        pollingState.captureError = ''
    end)
    if not captureSucceeded then pollingState.captureError = sanitizeText(captureError) end
end

local function splitRecordFields(recordLine)
    local recordFields = {}
    for fieldValue in string.gmatch(recordLine .. '|', '(.-)|') do
        recordFields[#recordFields + 1] = fieldValue
    end
    return recordFields
end

local function convertRecords(recordText)
    local convertedRecords = {}
    for recordLine in string.gmatch(recordText .. '\n', '(.-)\n') do
        if string.sub(recordLine, 1, 2) == 'R|' or string.sub(recordLine, 1, 2) == 'B|' then
            local recordFields = splitRecordFields(recordLine)
            local reporterIdentifier = recordFields[2] or '0'
            local reporterCandidate = pollingState.candidatesByIdentifier[reporterIdentifier]
            local reporterName = reporterCandidate and reporterCandidate.playerName or
                                 ('UID ' .. reporterIdentifier)
            local targetIdentifier = recordFields[3] or '0'
            local currentAccountIdentifier = recordFields[4] or '0'
            local gameStartTime = recordFields[5] or '0'
            local rawReasons = recordFields[6] or 'Không rõ'
            local complaintResult = recordFields[9] or 'Unknown'
            local displayReasons = recordFields[14] or ''
            local recordKind = string.sub(recordLine, 1, 1)
            convertedRecords[#convertedRecords + 1] = table.concat({
                recordKind, reporterIdentifier, reporterName, targetIdentifier,
                currentAccountIdentifier, gameStartTime, rawReasons,
                complaintResult, displayReasons
            }, '|')
        end
    end
    if #convertedRecords == 0 then return recordText end
    return table.concat(convertedRecords, '\n')
end

local pendingResponse = ComplaintMonitorRuntime.takePendingRecords()
if pendingResponse ~= nil and (string.sub(pendingResponse, 1, 2) == 'R|' or
                              string.sub(pendingResponse, 1, 2) == 'B|') then
    return convertRecords(pendingResponse)
end
if ComplaintMonitorRuntime.transportFault then
    return '#|soito|timeout_relogin'
end

if pollingState.buildingBaseline and
   (ComplaintMonitorRuntime.pendingReporterIdentifier or 0) == 0 and
   (ComplaintMonitorRuntime.sentRequestCount or 0) > 0 and
   (ComplaintMonitorRuntime.receivedResponseCount or 0) >=
       (ComplaintMonitorRuntime.sentRequestCount or 0) then
    local allReady = #pollingState.candidates > 0
    for _, candidate in ipairs(pollingState.candidates) do
        if not candidate.baselineComplete then allReady = false; break end
    end
    if allReady then pollingState.buildingBaseline = false end
end

captureCandidates()
if #pollingState.candidates == 0 then
    return '#|soito|empty|' .. sanitizeText(pollingState.captureError)
end

if pollingState.cooldownTicks > 0 then
    pollingState.cooldownTicks = pollingState.cooldownTicks - 1
    return '#|soito|cooldown|' .. tostring(#pollingState.candidates) ..
        '|result=' .. tostring(ComplaintMonitorRuntime.lastResultCode or 0) .. '|'
end

if pollingState.candidateIndex > #pollingState.candidates then
    pollingState.candidateIndex = 1
end
local reporterCandidate = pollingState.candidates[pollingState.candidateIndex]
local requestStatus = ComplaintMonitorRuntime.requestComplaintHistory(
    reporterCandidate.userIdentifier, reporterCandidate.worldIdentifier,
    not reporterCandidate.baselineComplete)
if requestStatus == '1' then
    pollingState.candidateIndex = pollingState.candidateIndex + 1
    if pollingState.candidateIndex > #pollingState.candidates then
        pollingState.candidateIndex = 1
        -- Normal scans continue on the next 750-ms tick. Only a server error
        -- introduces the 30-second backoff; never queue concurrent queries.
        pollingState.cooldownTicks = 0
    end
end
return '#|soito|q=' .. tostring(requestStatus) ..
    '|uid=' .. formatUserIdentifier(reporterCandidate.userIdentifier) ..
    '|count=' .. tostring(#pollingState.candidates) ..
    '|result=' .. tostring(ComplaintMonitorRuntime.lastResultCode or 0) ..
    '|raw=' .. sanitizeText(pendingResponse)
end)()

  end
  local ready, nextPoll, queued = false, 0, {}
  local wasDisabled=false
  local ignoredRequests=setmetatable({},{__mode='k'})
  local ignoreResponse=false
  local trackingSince=nil
  local queryAccount, querySeen = nil, {}
  m.queryStatus='Chờ lấy danh sách người chơi trong trận.'

  local function split(line)
    local fields={}
    for field in (line..'|'):gmatch('(.-)|') do fields[#fields+1]=field end
    return fields
  end
  local function syncLedger()
    if queryAccount==m.account then return end
    queryAccount=m.account;querySeen={};queued={}
    trackingSince=tonumber(m.api.now())
    for id in m.api.read(m.dir..'/query_seen.tsv'):gmatch('([^\n]+)\n') do querySeen[id]=true end
    -- R17 ledger rows also constitute a durable deduplication checkpoint. This
    -- closes the crash window between appending a report and its seen marker.
    for _,r in ipairs(m.records) do if r.source=='server_history' then querySeen[r.id]=true end end
  end

  local function accept(line)
    local f=split(line)
    if #f~=14 or (f[1]~='B' and f[1]~='R' and f[1]~='I') then return true end
    local uid,world=m.account:match('^(%d+)_(%d+)$')
    if f[3]~=uid or f[4]~=uid then return true end
    if not f[2]:match('^%d+$') or f[2]=='0' then return true end
    local gameTime=tonumber(f[5])
    local now=tonumber(m.api.now())
    if not now or not gameTime or gameTime<=0 or gameTime>now+300 then
      m.queryStatus='Máy chủ chưa cung cấp thời gian trận hợp lệ; chưa tính bản ghi.'
      return true
    end
    local candidate=ComplaintMonitorPolling and ComplaintMonitorPolling.candidatesByIdentifier[f[2]]
    if not candidate or not candidate.worldIdentifier then return true end
    local id='query:'..f[2]..':'..tostring(candidate.worldIdentifier)..':'..f[5]
    if querySeen[id] then return true end
    -- The target game can reject lobby queries during fighting. Its first
    -- accepted reply may already contain this match's report. A match started
    -- after monitoring was armed belongs to this session, even in a first reply.
    local freshMatch=trackingSince and gameTime>=trackingSince and now>=m.since
    if f[1]=='I' then
      m.api.append(m.dir..'/query_seen.tsv',id..'\n');querySeen[id]=true
      return true
    end
    local name=clean(candidate.playerName or f[2])
    local r={id=id,event=now,received=now,basis='first_received_time',desk=f[5],seq=f[2],
      reason=clean(f[14]),warn=clean(f[9]),
      subject='Bản ghi tố cáo từ '..name..' | trận '..m.formatTime(gameTime),source='server_history'}
    local row=table.concat({'R15',r.id,integer(r.event),integer(r.received),r.basis,
      r.desk,r.seq,r.reason,r.warn,r.subject,r.source},'\t')..'\n'
    m.api.append(m.path,row)
    m.records[#m.records+1]=r;m.seen[id]=true;querySeen[id]=true
    m.pending=m.pending+1;m.api.set(key('Pending'),m.pending)
    m.queryStatus='Đã nhận bản ghi tố cáo mới từ máy chủ.'
    return true
  end

  local function consume()
    if not m.refresh() or not m.enabled or m.retired then
      if ComplaintMonitorRuntime then ComplaintMonitorRuntime.pendingRecords={} end
      queued={};return
    end
    syncLedger()
    local runtime=ComplaintMonitorRuntime
    if runtime then
      -- A callback can precede the next network frame after an account switch.
      local uid,world=m.account:match('^(%d+)_(%d+)$')
      if runtime.identifierText(runtime.accountIdentifier)~=uid or
         tostring(runtime.accountWorldIdentifier)~=world then
        runtime.pendingRecords={};queued={};return
      end
      for _,line in ipairs(runtime.pendingRecords) do
        if ignoreResponse then line='I'..line:sub(2) end
        queued[#queued+1]=line
      end
      runtime.pendingRecords={}
    end
    while #queued>0 do
      accept(queued[1]) -- Retain the first failed append for the next tick.
      table.remove(queued,1)
    end
    m.notify()
  end

  function m.queryPulse()
    m.queryPulseCount=(m.queryPulseCount or 0)+1
    local ok,err=pcall(function()
      if m.retired or not m.enabled then return end
      consume()
      local clock=m.api.clock and m.api.clock() or m.api.now()
      if clock<nextPoll then return end
      nextPoll=clock+0.75 -- Match the donor's interval; one outstanding request.
      if not ready then
        local result=installDonor()
        if result~='OK' then error(result) end
        local original=ComplaintMonitorRuntime.collectComplaintRecords
        ComplaintMonitorRuntime.collectComplaintRecords=function(...)
          original(...)
          -- The callback persists and announces new records directly, without
          -- waiting for the next scan round or another chat command.
          consume()
        end
        local handle=ComplaintMonitorRuntime.handleComplaintResponse
        ComplaintMonitorRuntime.handleComplaintResponse=function(response,request,reporter,baselineOnly)
          ignoreResponse=ignoredRequests[request] and true or false
          if ignoreResponse then baselineOnly=true;ignoredRequests[request]=nil end
          local ok,result=pcall(handle,response,request,reporter,baselineOnly)
          ignoreResponse=false
          if not ok then error(result) end
          return result
        end
        ready=true
      end
      local status=pollDonor()
      m.lastQueryStatus=clean(status)
      m.queryError=''
      -- pollDonor normally drains records for the native Chap_To UI. Our
      -- callback already consumed them; keep this path for synchronous replies.
      if status:sub(1,2)=='R|' or status:sub(1,2)=='B|' then
        error('Unexpected undelivered donor record')
      elseif status:find('timeout_relogin',1,true) then
        m.queryStatus='Truy vấn hết hạn; cần đăng nhập lại để tránh nhận nhầm phản hồi.'
      elseif status:find('account_pending',1,true) then
        m.queryStatus='Chờ đăng nhập.'
      elseif status:find('empty|',1,true) then
        m.queryStatus='Chờ lấy danh sách người chơi trong trận.'
      elseif ComplaintMonitorRuntime.lastResultCode~=nil then
        m.queryStatus='Máy chủ trả lỗi '..tostring(ComplaintMonitorRuntime.lastResultCode)..'; chưa thể kết luận.'
      elseif ComplaintMonitorRuntime.sentRequestCount>0 then
        local count=#ComplaintMonitorPolling.candidates
        m.queryStatus='Đang theo dõi '..integer(count)..' người chơi; gửi='..
          integer(ComplaintMonitorRuntime.sentRequestCount)..', nhận='..
          integer(ComplaintMonitorRuntime.receivedResponseCount)..'.'
      elseif ComplaintMonitorRuntime.errorMessage~='' then
        m.queryStatus='Bộ theo dõi máy chủ chưa sẵn sàng: '..clean(ComplaintMonitorRuntime.errorMessage)
      else
        m.queryStatus=m.api.battle() and 'Game đang chặn truy vấn khi giao tranh; sẽ thử lại sau trận.' or 'Chưa gửi được truy vấn tố cáo.'
      end
    end)
    if not ok then m.queryError=clean(err);m.queryStatus='Bộ theo dõi máy chủ chưa sẵn sàng: '..clean(err) end
  end

  function m.stopQuery()
    m.retired=true
    local runtime=ComplaintMonitorRuntime
    if not runtime then return end
    local class=package.loaded['AOV.CSExtension.NetworkModule']
    if class and class.SendLobbyMsg==runtime.sendWrapper then
      class.SendLobbyMsg=runtime.originalSendLobbyMsg
    end
  end

  function m.querySetEnabled(value)
    if not value then
      wasDisabled=true;queued={}
      local active=ComplaintMonitorRuntime and ComplaintMonitorRuntime.activeRequest
      if active then ignoredRequests[active]=true end
      return
    end
    if wasDisabled and ComplaintMonitorPolling then
      for _,candidate in ipairs(ComplaintMonitorPolling.candidates) do candidate.baselineComplete=false end
      ComplaintMonitorPolling.buildingBaseline=true
    end
    if wasDisabled then trackingSince=tonumber(m.api.now()) end
    wasDisabled=false
  end
end
attachQueryMonitor(m)


function m.panel()
  local state=m.status()
  local now=number(m.api.now())
  if not now then return state end
  local rows=m.list('day',now)
  local lines={state}
  if #rows==0 then lines[#lines+1]='Chưa có bản ghi trong ngày.' end
  return table.concat(lines,'\n')
end
function m.column(index)
  if not m.refresh() then return '' end
  local now=number(m.api.now())
  if not now then return '' end
  local rows=m.list('day',now)
  local lines={}
  for i=#rows,math.max(1,#rows-49),-1 do
    local r=rows[i]
    local value=index==1 and m.formatTime(r.event):sub(12,19) or index==2 and clean(r.subject) or clean(r.reason)
    lines[#lines+1]=value
  end
  return table.concat(lines,'\n')
end
rawset(_G,globalKey,m)
return 'OK'
