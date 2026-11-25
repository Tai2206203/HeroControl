assert(dofile('Runtime/Runtime.lua')=='initialized')
local stopped=0
DoroCheatCheckToR9={enabled=true,stopQuery=function() stopped=stopped+1 end}
CS=setmetatable({},{__index=function() error('READ MEMORY must not access game APIs') end})
N=CS
for _,settings in ipairs({{}, {readMemoryOnly=true}, {readMemoryOnly=0}, {readMemoryOnly='false'}}) do
  local result=HeroControlRuntimePulse({settings=settings},'/fixture')
  assert(result:find('"code":"runtime_read_memory_only"',1,true),result)
  assert(DoroCheatCheckToR9.enabled==false and DoroCheatCheckToR9.retired==true)
end
assert(stopped==4)
print('READ MEMORY Lua gate passed: default ON, invalid values fail closed, no game API/prefs/patch load/query calls; monitor suspended.')
