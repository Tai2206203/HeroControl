assert(dofile('Runtime/Payload/ComplaintHistory.lua')=='OK')
local m=DoroCheatCheckToR9
m.api.account=function() return '123_1' end
m.api.root=function() return '/fixture' end
m.api.mkdir=function() end
m.api.get=function(_,fallback) return fallback end
m.api.read=function() return 'R15\told-mail\t1795580587\t1795580587\tserver_mail_time\t0\t0\t1\t0\tLịch sử bị tố cáo\tlive\n' end
assert(m.refresh())
assert(#m.records==1 and m.records[1].reason=='1')
assert(m.describeReason(m.records[1].reason)=='Rớt mạng/AFK')
assert(m.describeReason('Lý do từ máy chủ')=='Lý do từ máy chủ')
assert(m.describeReason('999'):find('999',1,true))
assert(m.command==nil)
print('Report reasons passed: existing numeric mail ledger displays the supplied enum title; unknown codes remain explicit; menu API only.')
