#ifndef AM_SECCOMP_FILTER_H
#define AM_SECCOMP_FILTER_H

/**
 * Builds the sandbox's seccomp filter and returns a file descriptor holding the
 * compiled BPF program, positioned at the start, ready to hand to bwrap's
 * --seccomp. The caller owns the descriptor.
 *
 * Returns -1 when no filter could be built, including when AppManager was
 * compiled without libseccomp. That is not fatal: the sandbox is weaker, and
 * the caller says so in the log.
 *
 * allow_bluetooth adds AF_BLUETOOTH to the socket families the app may use.
 * Without it a Bluetooth app cannot open its socket even with the bus rule.
 */
int am_seccomp_build_fd (int allow_bluetooth);

#endif /* AM_SECCOMP_FILTER_H */
