const builtin = @import("builtin");

/// Windows x86_64 direct register save/restore for setjmp/longjmp.
/// Avoids Microsoft CRT's `RtlUnwindEx` SEH unwinding which crashes in MCJIT
/// dynamic code because JIT stack frames have no system function table entries.
/// Implemented in assembly in `src/runtime/windows_sjlj.s`.
pub const is_windows_x64 = (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);

pub extern fn eiwa_setjmp(buf: ?*anyopaque) callconv(.c) c_int;
pub extern fn eiwa_longjmp(buf: ?*anyopaque, val: c_int) callconv(.c) noreturn;
