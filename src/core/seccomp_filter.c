/*
 * The sandbox's seccomp filter.
 *
 * This is flatpak's filter, deliberately: it is the one that a decade of running
 * untrusted desktop apps has shaped, and every entry in it answers a specific
 * escape. It is also what makes the portal identity trustworthy — without the
 * mount and user-namespace syscalls blocked, an app could restructure its own
 * mounts and rewrite /.flatpak-info to claim another app's permissions.
 *
 * Two rules about how it is written:
 *
 *  - Syscalls that no longer existing userspace expects to fail return ENOSYS,
 *    not EPERM, so that libc and language runtimes take their fallback path.
 *    clone3 is the important one: glibc calls it, sees ENOSYS, and falls back to
 *    clone, which the filter can then inspect. Returning EPERM instead breaks
 *    Chromium's own sandbox outright.
 *
 *  - The 32-bit secondary architecture is added to the filter, or a 32-bit
 *    binary inside a 64-bit AppImage would bypass the whole thing.
 */

#include "seccomp_filter.h"

#ifdef HAVE_LIBSECCOMP

/* memfd_create is a GNU extension in glibc's headers. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <asm/ioctls.h>
#include <linux/sched.h>
#include <seccomp.h>

/* Not in every kernel header, and the value is stable (CVE-2023-28100). */
#ifndef TIOCLINUX
#define TIOCLINUX 0x541C
#endif

/* PER_LINUX, the default personality. */
#define AM_PER_LINUX 0

/* clone()'s flags argument is arg1 rather than arg0 on s390 and CRIS. */
#if defined(__s390__) || defined(__s390x__) || defined(__CRIS__)
#define AM_CLONE_NEWUSER_CMP \
  SCMP_A1 (SCMP_CMP_MASKED_EQ, CLONE_NEWUSER, CLONE_NEWUSER)
#else
#define AM_CLONE_NEWUSER_CMP \
  SCMP_A0 (SCMP_CMP_MASKED_EQ, CLONE_NEWUSER, CLONE_NEWUSER)
#endif

struct am_rule
{
  int syscall_nr;
  int errnum;
  int use_arg;                 /* 0 = unconditional, 1 = compare one argument */
  struct scmp_arg_cmp arg;
};

static int
add_rules (scmp_filter_ctx ctx, const struct am_rule *rules, size_t n)
{
  size_t i;

  for (i = 0; i < n; i++)
    {
      int r;

      if (rules[i].use_arg)
        r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (rules[i].errnum),
                              rules[i].syscall_nr, 1, rules[i].arg);
      else
        r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (rules[i].errnum),
                              rules[i].syscall_nr, 0);

      /* A syscall libseccomp does not know, or one absent from a secondary
       * architecture, cannot be called either — skipping it is correct. Any
       * other failure means the filter would be incomplete, so give up rather
       * than install a filter that is not the one asked for. */
      if (r < 0 && r != -EDOM && r != -EFAULT && r != -EACCES && r != -EINVAL)
        return r;
    }

  return 0;
}

int
am_seccomp_build_fd (int allow_bluetooth)
{
  /* Everything is allowed except what follows. An allowlist would be stronger
   * and would also break every app that uses a syscall nobody thought of. */
  scmp_filter_ctx ctx = seccomp_init (SCMP_ACT_ALLOW);
  int fd = -1;
  int r;
  int family;
  int last_allowed;

  static const int allowed_families[] = {
    AF_UNSPEC, AF_LOCAL, AF_INET, AF_INET6, AF_NETLINK,
  };

  const struct am_rule blocked[] = {
    /* Kernel surfaces with a history of local privilege escalation and no use
     * to a desktop app. */
    { SCMP_SYS (syslog),         EPERM, 0, { 0 } },
    { SCMP_SYS (uselib),         EPERM, 0, { 0 } },
    { SCMP_SYS (acct),           EPERM, 0, { 0 } },
    { SCMP_SYS (quotactl),       EPERM, 0, { 0 } },
    /* The kernel keyring is shared with the rest of the session. */
    { SCMP_SYS (add_key),        EPERM, 0, { 0 } },
    { SCMP_SYS (keyctl),         EPERM, 0, { 0 } },
    { SCMP_SYS (request_key),    EPERM, 0, { 0 } },
    /* NUMA calls that have been used to corrupt kernel memory. */
    { SCMP_SYS (move_pages),     EPERM, 0, { 0 } },
    { SCMP_SYS (mbind),          EPERM, 0, { 0 } },
    { SCMP_SYS (get_mempolicy),  EPERM, 0, { 0 } },
    { SCMP_SYS (set_mempolicy),  EPERM, 0, { 0 } },
    { SCMP_SYS (migrate_pages),  EPERM, 0, { 0 } },
    /* Namespace and mount manipulation: the route to rewriting the sandbox's
     * own view of the filesystem, and with it /.flatpak-info. */
    { SCMP_SYS (unshare),        EPERM, 0, { 0 } },
    { SCMP_SYS (setns),          EPERM, 0, { 0 } },
    { SCMP_SYS (mount),          EPERM, 0, { 0 } },
    { SCMP_SYS (umount),         EPERM, 0, { 0 } },
    { SCMP_SYS (umount2),        EPERM, 0, { 0 } },
    { SCMP_SYS (pivot_root),     EPERM, 0, { 0 } },
    { SCMP_SYS (chroot),         EPERM, 0, { 0 } },
    /* Seeing other processes' performance data is seeing their behaviour. */
    { SCMP_SYS (perf_event_open), EPERM, 0, { 0 } },
    /* Attaching to another process would defeat everything else here. */
    { SCMP_SYS (ptrace),         EPERM, 0, { 0 } },
    /* A new user namespace would let the app become root inside it and mount. */
    { SCMP_SYS (clone),          EPERM, 1, AM_CLONE_NEWUSER_CMP },
    /* TIOCSTI injects keystrokes into the controlling terminal, which is how a
     * sandboxed command-line app escapes into the shell that started it
     * (CVE-2017-5226). TIOCLINUX is the same trick on the console
     * (CVE-2023-28100). Masked to 32 bits because the request reaches the
     * kernel sign-extended. */
    { SCMP_SYS (ioctl),          EPERM, 1,
      SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCSTI) },
    { SCMP_SYS (ioctl),          EPERM, 1,
      SCMP_A1 (SCMP_CMP_MASKED_EQ, 0xFFFFFFFFu, (int) TIOCLINUX) },
    /* A non-default personality changes how other syscalls behave, including
     * turning off address-space randomization. */
    { SCMP_SYS (personality),    EPERM, 1,
      SCMP_A0 (SCMP_CMP_NE, AM_PER_LINUX) },

    /* ENOSYS, not EPERM: userspace has a working fallback for each of these
     * and takes it when told the kernel is too old. */
    { SCMP_SYS (clone3),         ENOSYS, 0, { 0 } },
    { SCMP_SYS (open_tree),      ENOSYS, 0, { 0 } },
    { SCMP_SYS (move_mount),     ENOSYS, 0, { 0 } },
    { SCMP_SYS (fsopen),         ENOSYS, 0, { 0 } },
    { SCMP_SYS (fsconfig),       ENOSYS, 0, { 0 } },
    { SCMP_SYS (fsmount),        ENOSYS, 0, { 0 } },
    { SCMP_SYS (fspick),         ENOSYS, 0, { 0 } },
    { SCMP_SYS (mount_setattr),  ENOSYS, 0, { 0 } },
  };

  if (ctx == NULL)
    return -1;

  /* Without this a 32-bit process inside the sandbox runs unfiltered. EEXIST
   * means the architecture is already covered, which is fine. */
#if defined(__x86_64__)
  r = seccomp_arch_add (ctx, SCMP_ARCH_X86);
#elif defined(__aarch64__)
  r = seccomp_arch_add (ctx, SCMP_ARCH_ARM);
#else
  r = 0;
#endif
  if (r < 0 && r != -EEXIST)
    goto out;

  r = add_rules (ctx, blocked, sizeof (blocked) / sizeof (blocked[0]));
  if (r < 0)
    goto out;

  /* Socket families. Everything outside the allowlist is refused, which takes
   * away CAN, AX.25, packet sockets and the rest of the protocol families no
   * desktop app asks for and several of which have had holes.
   *
   * libseccomp can only compare one argument at a time, so the families are
   * expressed as the gaps below the highest allowed value plus one rule for
   * everything above it. */
  last_allowed = allow_bluetooth ? AF_BLUETOOTH : AF_NETLINK;

  for (family = 0; family < last_allowed; family++)
    {
      size_t i;
      int allowed = 0;

      for (i = 0; i < sizeof (allowed_families) / sizeof (allowed_families[0]); i++)
        {
          if (allowed_families[i] == family)
            {
              allowed = 1;
              break;
            }
        }
      if (allow_bluetooth && family == AF_BLUETOOTH)
        allowed = 1;
      if (allowed)
        continue;

      r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (EAFNOSUPPORT), SCMP_SYS (socket), 1,
                            SCMP_A0 (SCMP_CMP_EQ, (unsigned int) family));
      if (r < 0 && r != -EDOM && r != -EFAULT && r != -EACCES && r != -EINVAL)
        goto out;
    }

  r = seccomp_rule_add (ctx, SCMP_ACT_ERRNO (EAFNOSUPPORT), SCMP_SYS (socket), 1,
                        SCMP_A0 (SCMP_CMP_GE, (unsigned int) (last_allowed + 1)));
  if (r < 0 && r != -EDOM && r != -EFAULT && r != -EACCES && r != -EINVAL)
    goto out;

  /* A memfd rather than a temporary file: nothing to name, nothing to clean up,
   * and no window in which another process could read or replace the program. */
  fd = memfd_create ("am-seccomp", 0);
  if (fd < 0)
    goto out;

  r = seccomp_export_bpf (ctx, fd);
  if (r < 0)
    {
      close (fd);
      fd = -1;
      goto out;
    }

  /* bwrap reads the program from the start of the descriptor. */
  if (lseek (fd, 0, SEEK_SET) != 0)
    {
      close (fd);
      fd = -1;
    }

out:
  seccomp_release (ctx);
  return fd;
}

#else /* !HAVE_LIBSECCOMP */

int
am_seccomp_build_fd (int allow_bluetooth)
{
  (void) allow_bluetooth;
  return -1;
}

#endif /* HAVE_LIBSECCOMP */
