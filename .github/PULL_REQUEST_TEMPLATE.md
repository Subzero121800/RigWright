## What does this change?

## How was it tested?
- [ ] `.\tests\Test-Catalog.ps1` passes (`-Winget` if apps changed)
- [ ] `.\tests\Test-Server.ps1` passes
- [ ] Tweaks: applied, state = applied, undone, state = not applied - on Windows build(s): ___

## Checklist
- [ ] Risk / side effects / `policy` set honestly
- [ ] Script tweaks include `undoScript` (and `detect`)
- [ ] No downloads-and-execute, nothing disables Windows Update or Defender
- [ ] `.ps1`/`.psm1` files are ASCII only
- [ ] CHANGELOG.md updated under Unreleased