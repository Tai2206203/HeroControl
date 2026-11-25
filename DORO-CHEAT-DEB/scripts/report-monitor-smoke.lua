-- Exercise the shipped (and patch-embedded) monitor, not a rewritten model.
assert(dofile('Runtime/Payload/ComplaintHistory.lua')=='OK')
local m=DoroCheatCheckToR9
assert(m.version==26)
m.enabled=true
m.account="123_1"
m.refresh=function() return true end
m.api.now=function() return 100 end
m.api.get=function(_,fallback) return fallback end
m.api.set=function() end
m.notify=function() end
m.querySetEnabled=function() end
local pulses=0
m.queryPulse=function() pulses=pulses+1 end
m.installMail=function() error('mail_binding_not_ready') end
m.tick()
assert(pulses==1,'mail initialization blocked history query')
assert(m.mailError:find('mail_binding_not_ready',1,true))
local status=m.setEnabled(true)
assert(pulses==2,'mail initialization blocked enable-time query')
assert(not status:find('Check tố chưa thực hiện được',1,true),status)
m.installMail=function() return true end
m.scan=function() error('mail_list_not_ready') end
m.tick()
assert(pulses==3,'mail scan blocked history query')
assert(m.mailError:find('mail_list_not_ready',1,true))
m.scan=function() return true end
m.tick()
assert(pulses==4 and m.mailError=='','mail recovery was not reflected')
m.enabled=false
m.tick()
assert(pulses==4,'disabled monitor sent a query')
print('Report monitor passed: enable/tick queries survive mail failures; recovery and disable verified. No real server accessed.')

assert(m.command==nil,'chat-command entry point must be removed')
assert(m.describeReason('1')=='Rớt mạng/AFK')
assert(m.describeReason('999'):find('999',1,true))
