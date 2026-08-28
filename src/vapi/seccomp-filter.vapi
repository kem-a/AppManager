/*
 * Vala bindings for the sandbox seccomp filter (src/core/seccomp_filter.c).
 * libseccomp ships no Vala vapi, and the filter is a few hundred lines of C
 * either way, so the helper exposes one function instead.
 */
[CCode (cheader_filename = "seccomp_filter.h")]
namespace AppManager.Seccomp {
    /**
     * Returns a descriptor holding the compiled BPF program for bwrap's
     * --seccomp, or -1 when no filter could be built — including when this
     * build has no libseccomp.
     */
    [CCode (cname = "am_seccomp_build_fd")]
    public int build_fd (bool allow_bluetooth);
}
