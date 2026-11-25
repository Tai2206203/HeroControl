DORO-CHEAT native string protection

Scope
30 selected native constants: dynamic API/class names, provider paths and the
runtime pulse call format. ProtectedStrings.def is the reviewable registry.
A C++17 translation unit links into backend/helper/launch bridge, overlay and runtime; existing
Objective-C .m files keep their original language and ABI. The app's Swift code,
Lua/IFix payloads, images, settings, JSON keys and exported ABI are unchanged.
This does not encrypt the whole TIPA or hide every algorithm/offset/resource.

Lifecycle and performance
Each UTF-8 constant is decoded only on first use with C++ thread-safe static
initialization. std::array copies the temporary oxorany result within the same
full expression, preventing dangling pointers. NSString values are cached too.
No additional obfuscation loop runs in the ESP drawing path. Cleartext remains
in process memory after use: obfuscation is not secret storage or cryptography.

Build
The vendored MIT source is pinned, byte-preserved and hash-checked. No remote
fetch occurs during CI. Upstream opaque predicate functions compile separately
without LTO; all protection objects use -O2 and hidden visibility. Native release
links strip local symbols (-Wl,-x), preserving the required exported ABI.
Debug-disable macros fail compilation rather than silently disable protection.
Only one component group can be selected per object. The matching object pair
must be linked, including the separate upstream predicate definitions.
The TIPA contains the upstream license.

Verification
scripts/test-protection.sh runs concurrent first-use, stable-lifetime, exact
value and component-isolation checks on macOS for all three component groups.
scripts/verify-protection.py checks pinned source hashes, call-site grouping,
build wiring and printable plaintext tokens in each built object and complete
native artifact. Required imported/exported symbol names remain intact; their
names can still disclose behavior. Tests contain expected cleartext and are not
shipped. Source-manifest.json still checks exact source generation.
Windows host checks do not replace the Apple SDK link/device checks in CI.

Protection limits and possible next layers
MCP is a tool interface; it does not change the basic limits of client-side
protection. Anyone who can execute and inspect the app can observe decoded data.
LLVM control-flow obfuscation can increase analysis effort but needs a compatible
Apple toolchain and device performance validation. It is not enabled here.
A license server can keep signing private keys and authorization decisions off
the device; no such server or network dependency is added by this change.
Do not place an embedded shared secret behind oxorany and assume it is secure.

Sources
https://github.com/llxiaoyuan/oxorany
https://mas.owasp.org/MASTG/knowledge/generic/MASVS-RESILIENCE/MASTG-KNOW-0111/
https://github.com/obfuscator-llvm/obfuscator/wiki/Control-Flow-Flattening
