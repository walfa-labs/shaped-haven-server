//! Socket option shims for the transport layer.
//!
//! DESIGN.md §5 requires `TCP_NODELAY` on every client connection. The
//! `std.Io` networking layer sets `SO_REUSEADDR` but exposes no hook for
//! further socket options, and `std.posix.setsockopt` is `@compileError` on
//! Windows. So this module reaches for the same primitive `std.Io.Threaded`
//! itself uses: the AFD `IOCTL_AFD_SOCKOPT` device control on Windows, and
//! plain `setsockopt(2)` everywhere else.

const std = @import("std");

pub const SetNoDelayError = error{ SetNoDelayFailed };

/// Enable `TCP_NODELAY` on an accepted client socket.
///
/// A failure here is not fatal to the connection: the caller logs and
/// continues, trading a little latency for a working link.
pub fn setTcpNoDelay(handle: std.posix.fd_t) SetNoDelayError!void {
    if (comptime @import("builtin").os.tag == .windows) return windowsSetNoDelay(handle);
    std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &.{1}) catch
        return error.SetNoDelayFailed;
}

fn windowsSetNoDelay(handle: std.posix.fd_t) SetNoDelayError!void {
    const windows = std.os.windows;

    var enabled: u32 = 1;
    const info = windows.AFD.SOCKOPT_INFO{
        .mode = .set,
        .level = std.os.windows.ws2_32.IPPROTO.TCP,
        .optname = std.os.windows.ws2_32.TCP.NODELAY,
        .optval = &enabled,
        .optlen = @sizeOf(@TypeOf(enabled)),
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.SOCKOPT,
        &info,
        @sizeOf(@TypeOf(info)),
        null,
        0,
    );
    if (status != .SUCCESS) return error.SetNoDelayFailed;
}
