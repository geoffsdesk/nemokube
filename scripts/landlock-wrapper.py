#!/usr/bin/env python3
"""
NemoKube Landlock Wrapper
=========================
K8s-native translation of NemoClaw's Landlock filesystem policy.
Applies Landlock rules matching openclaw-sandbox.yaml before exec'ing
the OpenClaw gateway. If Landlock is unavailable (kernel too old or
seccomp blocks the syscalls), falls back to running without it and
logs a warning.

Filesystem policy from openclaw-sandbox.yaml:
  read_only:  /usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log,
              /sandbox, /sandbox/.openclaw
  read_write: /tmp, /dev/null, /sandbox/.openclaw-data, /sandbox/.nemoclaw

Usage:
  python3 landlock-wrapper.py openclaw gateway run
"""
import ctypes
import ctypes.util
import os
import struct
import sys

# ── Landlock constants (kernel UAPI) ────────────────────────────────────────
# Syscall numbers (x86_64)
SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446

# Landlock ABI v1 access rights for filesystem
LANDLOCK_ACCESS_FS_EXECUTE = 1 << 0
LANDLOCK_ACCESS_FS_WRITE_FILE = 1 << 1
LANDLOCK_ACCESS_FS_READ_FILE = 1 << 2
LANDLOCK_ACCESS_FS_READ_DIR = 1 << 3
LANDLOCK_ACCESS_FS_REMOVE_DIR = 1 << 4
LANDLOCK_ACCESS_FS_REMOVE_FILE = 1 << 5
LANDLOCK_ACCESS_FS_MAKE_CHAR = 1 << 6
LANDLOCK_ACCESS_FS_MAKE_DIR = 1 << 7
LANDLOCK_ACCESS_FS_MAKE_REG = 1 << 8
LANDLOCK_ACCESS_FS_MAKE_SOCK = 1 << 9
LANDLOCK_ACCESS_FS_MAKE_FIFO = 1 << 10
LANDLOCK_ACCESS_FS_MAKE_BLOCK = 1 << 11
LANDLOCK_ACCESS_FS_MAKE_SYM = 1 << 12

# Rule type
LANDLOCK_RULE_PATH_BENEATH = 1

# Composite access sets
READ_ONLY = (
    LANDLOCK_ACCESS_FS_EXECUTE |
    LANDLOCK_ACCESS_FS_READ_FILE |
    LANDLOCK_ACCESS_FS_READ_DIR
)

READ_WRITE = (
    LANDLOCK_ACCESS_FS_EXECUTE |
    LANDLOCK_ACCESS_FS_READ_FILE |
    LANDLOCK_ACCESS_FS_READ_DIR |
    LANDLOCK_ACCESS_FS_WRITE_FILE |
    LANDLOCK_ACCESS_FS_REMOVE_DIR |
    LANDLOCK_ACCESS_FS_REMOVE_FILE |
    LANDLOCK_ACCESS_FS_MAKE_CHAR |
    LANDLOCK_ACCESS_FS_MAKE_DIR |
    LANDLOCK_ACCESS_FS_MAKE_REG |
    LANDLOCK_ACCESS_FS_MAKE_SOCK |
    LANDLOCK_ACCESS_FS_MAKE_FIFO |
    LANDLOCK_ACCESS_FS_MAKE_BLOCK |
    LANDLOCK_ACCESS_FS_MAKE_SYM
)

ALL_ACCESS = READ_WRITE  # All ABI v1 rights

# ── Filesystem rules matching openclaw-sandbox.yaml ─────────────────────────
READ_ONLY_PATHS = [
    "/usr",
    "/lib",
    "/lib64",         # Symlink on many systems
    "/proc",
    "/dev/urandom",
    "/app",
    "/etc",
    "/var/log",
    "/sandbox",
    "/sandbox/.openclaw",
]

READ_WRITE_PATHS = [
    "/tmp",
    "/dev/null",
    "/sandbox/.openclaw-data",
    "/sandbox/.nemoclaw",
]

# ── libc wrapper ────────────────────────────────────────────────────────────
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


def syscall(nr, *args):
    """Raw syscall wrapper."""
    ret = libc.syscall(nr, *[ctypes.c_long(a) for a in args])
    if ret < 0:
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno))
    return ret


def landlock_create_ruleset(handled_access_fs):
    """Create a Landlock ruleset. Returns the ruleset fd."""
    # struct landlock_ruleset_attr { __u64 handled_access_fs; }
    attr = struct.pack("Q", handled_access_fs)
    attr_buf = ctypes.create_string_buffer(attr)
    return syscall(
        SYS_LANDLOCK_CREATE_RULESET,
        ctypes.addressof(attr_buf),
        len(attr),
        0,  # flags
    )


def landlock_add_rule(ruleset_fd, path, allowed_access):
    """Add a path-beneath rule to the ruleset."""
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    try:
        # struct landlock_path_beneath_attr { __u64 allowed_access; __s32 parent_fd; }
        # Note: struct has padding, total size is 12 bytes + 4 padding = 16
        attr = struct.pack("Qi", allowed_access, fd)
        attr_buf = ctypes.create_string_buffer(attr)
        syscall(
            SYS_LANDLOCK_ADD_RULE,
            ruleset_fd,
            LANDLOCK_RULE_PATH_BENEATH,
            ctypes.addressof(attr_buf),
            0,  # flags
        )
    finally:
        os.close(fd)


def landlock_restrict_self(ruleset_fd):
    """Enforce the ruleset on this process and all future children."""
    syscall(SYS_LANDLOCK_RESTRICT_SELF, ruleset_fd, 0)


def apply_landlock():
    """Apply Landlock rules matching NemoClaw's openclaw-sandbox.yaml."""
    print("[landlock-wrapper] Applying Landlock filesystem restrictions...")

    # Create ruleset handling all ABI v1 filesystem access rights
    ruleset_fd = landlock_create_ruleset(ALL_ACCESS)
    print(f"[landlock-wrapper] Ruleset created (fd={ruleset_fd})")

    # Add read-only rules
    for path in READ_ONLY_PATHS:
        if os.path.exists(path):
            try:
                landlock_add_rule(ruleset_fd, path, READ_ONLY)
                print(f"[landlock-wrapper]   RO: {path}")
            except OSError as e:
                print(f"[landlock-wrapper]   SKIP (RO) {path}: {e}")

    # Add read-write rules
    for path in READ_WRITE_PATHS:
        # Create dirs if they don't exist (before Landlock locks down)
        if not os.path.exists(path) and path.startswith("/sandbox"):
            try:
                os.makedirs(path, exist_ok=True)
            except OSError:
                pass
        if os.path.exists(path):
            try:
                landlock_add_rule(ruleset_fd, path, READ_WRITE)
                print(f"[landlock-wrapper]   RW: {path}")
            except OSError as e:
                print(f"[landlock-wrapper]   SKIP (RW) {path}: {e}")

    # Enforce — after this, the process (and children) are restricted
    landlock_restrict_self(ruleset_fd)
    os.close(ruleset_fd)
    print("[landlock-wrapper] Landlock restrictions ACTIVE")


def main():
    if len(sys.argv) < 2:
        print("Usage: landlock-wrapper.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    try:
        apply_landlock()
    except OSError as e:
        # ENOSYS (38) = kernel doesn't support Landlock
        # EPERM (1) = seccomp blocks the syscall
        # EOPNOTSUPP (95) = Landlock disabled in kernel config
        if e.errno in (38, 1, 95):
            print(
                f"[landlock-wrapper] WARNING: Landlock unavailable (errno={e.errno}: {e.strerror}). "
                f"Running without filesystem restrictions. "
                f"Ensure the custom seccomp profile is installed and the pod references it.",
                file=sys.stderr,
            )
        else:
            print(f"[landlock-wrapper] ERROR: Unexpected Landlock failure: {e}", file=sys.stderr)
            sys.exit(1)

    # Exec the target command — replaces this process
    cmd = sys.argv[1:]
    print(f"[landlock-wrapper] exec: {' '.join(cmd)}")
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
