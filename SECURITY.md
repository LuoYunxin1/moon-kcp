# Security Policy

MoonKCP parses untrusted datagrams. Report suspected memory-safety, resource-exhaustion, or protocol-validation issues privately to the repository owner before public disclosure. Include a minimal reproducer, the affected commit, target backend, and the expected versus actual behavior. Do not include secrets or live production traffic.

Until a security contact is published in repository settings, open a private GitHub Security Advisory for `LuoYunxin1/moon-kcp` if the repository supports it. Public issues are appropriate for non-sensitive bugs.

The library does not open sockets. Integrators must enforce network-level rate limits, peer authentication, payload budgets, and session lifecycle policies appropriate to their application.