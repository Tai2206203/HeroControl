#!/usr/bin/env python3
"""Import the user's decoded patch payloads; never modify the reference/game files."""
import argparse
import hashlib
import json
from pathlib import Path


def seven_bit(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def upgrade_complaint_script(script):
    script = script.replace("if f[1]=='I' or (f[1]=='B' and not freshMatch) then", "if f[1]=='I' then")
    script = script.replace('existing.version == 22', 'existing.version == 24').replace('version=22,', 'version=24,')
    old_tick = """    m.mailReady=m.installMail()
    m.scan('poll')
    m.queryPulse()
    m.notify()"""
    new_tick = """    -- Mail is optional: a broken/unready mailbox must not block history queries.
    m.queryPulse()
    local mailOK,mailError=pcall(function()
      m.mailReady=m.installMail()
      m.scan('poll')
    end)
    m.mailError=mailOK and '' or clean(mailError)
    m.notify()"""
    assert script.count(old_tick) == 1
    script = script.replace(old_tick, new_tick)
    script = script.replace("      m.mailReady=m.installMail();m.scan('cached')", """      local mailOK,mailError=pcall(function() m.mailReady=m.installMail();m.scan('cached') end)
      m.mailError=mailOK and '' or clean(mailError)""")
    script = script.replace('  function m.queryPulse()\n', """  function m.queryPulse()
    m.queryPulseCount=(m.queryPulseCount or 0)+1
""")
    script = script.replace('      local status=pollDonor()', """      local status=pollDonor()
      m.lastQueryStatus=clean(status)
      m.queryError=''""")
    script = script.replace("    if not ok then m.queryStatus='Bộ theo dõi máy chủ chưa sẵn sàng: '..clean(err) end", "    if not ok then m.queryError=clean(err);m.queryStatus='Bộ theo dõi máy chủ chưa sẵn sàng: '..clean(err) end")
    script = script.replace('        -- Stage a complete snapshot', '        pollingState.rosterPlayerCount=playerCount\n        -- Stage a complete snapshot')
    script = script.replace('        pollingState.captureSequence = pollingState.captureSequence + 1', '        pollingState.rosterEligibleCount=#capturedPlayers\n        pollingState.captureSequence = pollingState.captureSequence + 1')
    script=script.replace('existing.version == 24','existing.version == 25').replace('version=24,','version=25,')
    # The credit-change enum in the supplied dump names code 1 GUAJI (AFK).
    reasons="""function m.describeReason(value)
  if value==nil or tostring(value)=='' then return 'Máy chủ chưa cung cấp lý do chi tiết' end
  local code=tonumber(value)
  if not code then return clean(value) end
  local titles={[1]='Rớt mạng/AFK',[2]='Cố ý bị hạ',[3]='Chơi tiêu cực',[4]='Chửi bới/lăng mạ',
    [5]='Dàn xếp trận đấu',[6]='Dùng phần mềm gian lận',[7]='Rớt mạng/AFK',[14]='Chửi bới/lăng mạ',
    [20]='Trình độ chơi không phù hợp',[21]='Rời trận'}
  return titles[code] or ('Máy chủ trả mã lý do '..tostring(code)..'; chưa có mô tả chi tiết')
end
"""
    script=script.replace('local function number(v)',reasons+'\nlocal function number(v)',1)
    start=script.index('function m.command(command)')
    finish=script.index('-- Retire the older observer',start)
    script=script[:start]+"""function m.setEnabled(value)
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

"""+script[finish:]
    script=script.replace(' /checkto day để xuất danh sách.',' Xem lịch sử trong menu Hero Control.')
    # The native HUD owns all receipt presentation; never open the game's tips UI.
    script=script.replace('existing.version == 25','existing.version == 26').replace('version=25,','version=26,')
    tip_start=script.index('  tip=function(text)')
    tip_end=script.index('  mail=function()',tip_start)
    script=script[:tip_start]+script[tip_end:]
    notice_start=script.index('function m.notify()')
    notice_end=script.index('function m.tick()',notice_start)
    script=script[:notice_start]+"""function m.notify()
  -- Drain the legacy counter after durable receipt storage. The HUD observes
  -- the ledger and presents notices through its own menu shortcut only.
  if m.pending<=0 or m.retired then return end
  local ok,err=pcall(function()
    if not m.refresh() then return end
    m.api.set(key('Pending'),0)
    m.pending=0
  end)
  if not ok then fail(err) end
end

"""+script[notice_end:]
    assert 'OpenTips' not in script and 'm.api.tip' not in script
    assert '/checkto' not in script
    return script


def import_reference(source, destination):
    analysis = source / 'analysis_heroskin/modified'
    destination.mkdir(parents=True, exist_ok=True)
    entries = []
    for name in ('HeroSkin_1', 'HeroSkin_2'):
        payload = (analysis / (name + '.decrypted.bin')).read_bytes()
        metadata = json.loads((analysis / (name + '.json')).read_text('utf8'))
        assert len(payload) == metadata['parsed_bytes'], 'Unparsed patch bytes'
        assert payload[:8].hex() == metadata['magic']
        original = hashlib.sha256(payload).hexdigest()
        if name == 'HeroSkin_1':
            # The donor discards baseline history. Keep the server's available
            # baseline records too; retain account checks, FIFO and deduplication.
            script = (analysis / 'HeroSkin_1/strings/217.lua').read_text('utf8')
            old = script.encode('utf8')
            condition = "if f[1]=='I' or (f[1]=='B' and not freshMatch) then"
            assert script.count(condition) == 1
            updated = upgrade_complaint_script(script)
            before = seven_bit(len(old)) + old
            after = updated.encode('utf8')
            assert payload.count(before) == 1, 'Donor Lua string does not match patch'
            payload = payload.replace(before, seven_bit(len(after)) + after, 1)
            # Replace donor menu callbacks too; no chat-command entry points remain.
            for index, enabled in [(224, 'true'), (225, 'false')]:
                old_callback=metadata['strings'][index].encode('utf8')
                callback=("return rawget(_G,'DoroCheatCheckToR9').setEnabled("+enabled+")").encode('utf8')
                encoded=seven_bit(len(old_callback))+old_callback
                assert payload.count(encoded)==1
                payload=payload.replace(encoded,seven_bit(len(callback))+callback,1)
            (destination / 'ComplaintHistory.lua').write_text(updated, encoding='utf8', newline='\n')
        filename = name + '.patch'
        (destination / filename).write_bytes(payload)
        entries.append({'file': filename, 'sourceSHA256': original,
                        'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload),
                        'assembly': metadata['assembly']})
    manifest = {'schemaVersion': 1, 'unityUUID': '298E718A-DA06-33B8-8253-910447B649E3',
                'patches': entries, 'historyScope': 'server_available_per_known_player',
                'allServerHistoryGuaranteed': False}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf8', newline='\n')
    print('Imported both decoded patches; original reference files unchanged.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('reference', type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent.parent / 'Runtime/Payload')
    args = parser.parse_args()
    import_reference(args.reference, args.output)
