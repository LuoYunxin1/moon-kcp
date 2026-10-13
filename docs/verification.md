# Verification and implementation scale

This record reflects the local checkout on 2026-10-13. It distinguishes checks that ran here from native verification reserved for CI.

## Library source size

The root MoonBit library package contains 1,760 physical lines across its non-test `.mbt` implementation files: `config.mbt` (207), `moon-kcp.mbt` (3), `state.mbt` (1,301), and `wire.mbt` (249). The count includes blank lines and excludes test files, generated interfaces, examples, commands, Markdown, and configuration. Recount with Python from the repository root:

```python
from pathlib import Path
files = [p for p in Path(".").glob("*.mbt")
         if not p.name.endswith(("_test.mbt", "_wbtest.mbt"))]
print(sum(len(p.read_text(encoding="utf-8").splitlines()) for p in files))
```

## Local verification

Toolchain: Moon `0.1.20260920`, Moonc `0.10.14+7d59c7ec9`.

- `moon info` completed with no generated interface changes; `moon fmt --check` passed.
- `moon check --deny-warn` passed for `wasm-gc`, `wasm`, `js`, and `native`.
- `moon test --deny-warn` passed on `wasm-gc`, `wasm`, and `js` with 54 tests per target.
- Library and all three examples built with `--deny-warn` on `wasm-gc`, `wasm`, and `js`.
- `moon run` executed the codec, loopback, and retransmission examples on `wasm-gc` successfully. The loopback delivered an 11-byte message; the retransmission example recovered one intentionally dropped datagram and cleared its outstanding segment after ACK.
- Native `moon test` could not run locally because this Windows environment has no `cc`, `gcc`, or `clang`. No local native test/build result is claimed; the repository CI matrix includes native checks, builds, and tests for a runner with a C compiler.

Rerun the matrix commands in `.github/workflows/ci.yml` before relying on a later code revision; this record is a dated local result, not a substitute for CI.
