assert(dofile('Runtime/Payload/ComplaintHistory.lua')=='OK')
local m=DoroCheatCheckToR9
assert(m.version==26 and m.command==nil and m.api.tip==nil)
local writes={}
m.refresh=function() return true end
m.api.set=function(key,value) writes[key]=value end
m.api.tip=function() error('game popup must never be called') end
m.api.battle=function() error('game popup routing must not be used') end
m.account='123_1';m.pending=3;m.records={{id='keep',reason='AFK'}}
m.notify()
assert(m.pending==0 and #m.records==1 and m.records[1].id=='keep')
assert(writes['vitduck.CheckTo.R15.123_1.Pending']==0)
m.pending=2;m.api.set=function() error('storage unavailable') end
m.notify();assert(m.pending==2 and #m.records==1)
print('Menu-only receipts passed: no game tips/battle UI, legacy count drained, ledger retained and failed writes retry.')
