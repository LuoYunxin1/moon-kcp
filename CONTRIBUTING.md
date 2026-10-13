# Contributing

- Keep the public API independent of sockets and event loops.
- Any wire behavior change must include a focused protocol test and a compatibility note.
- Never copy upstream C/Go implementation code. Attribute any future imported fixture and check its license first.
- Run `moon info`, `moon fmt`, `moon test`, and the target builds listed in the CI workflow before opening a pull request.
- Keep each commit reviewable and behavior-focused; do not split a single trivial change into multiple commits to inflate history.