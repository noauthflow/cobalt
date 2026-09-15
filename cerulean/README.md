# cerulean

Completely enable/disable a display at the compositor level — closer to "unplug the cable" than anything Apple's own System Settings offers (macOS has no public API or UI for this; the old `CGSRemoveDisplayFromElectronicStack` trick died years ago).

## display control

```
cerulean list     # main + external display IDs
cerulean off      # disable every external display — vanishes from the system entirely
cerulean on       # re-enable what 'off' disabled (state remembered in ~/.cerulean_disabled)
cerulean on-all   # re-enable everything known, emergency reset
```

## how display control works

Uses private SkyLight framework APIs (same family BetterDisplay uses). The signatures below were reverse-engineered on macOS 27 (`dyld_info -exports` + brute-force arg permutation) — **the arg order does not match the old CGS headers** floating around online:

```c
CGSConnectionID SLSMainConnectionID();
CGError SLSBeginDisplayConfiguration(CGSDisplayConfigRef *config_out, CGSConnectionID cid);      // config FIRST
CGError SLSConfigureDisplayEnabled(CGSDisplayConfigRef config, CGDirectDisplayID display,
                                   boolean_t enabled, CGSConnectionID cid);                       // enabled BEFORE cid
CGError SLSCompleteDisplayConfiguration(CGSDisplayConfigRef config, CGSConnectionID cid,
                                        uint32_t option);                                          // option 3 works
CGError SLSCancelDisplayConfiguration(CGSDisplayConfigRef config, CGSConnectionID cid);          // config FIRST
```

Gotchas encountered along the way:

- Swift `Bool` is 1 byte; SLS `boolean_t` is a 4-byte C int. Passing `Bool` corrupts the stack and segfaults.
- `SLSConfigureDisplayEnabled` returns success (0) for *any* arg order that puts `config` in x0 — it just no-ops. The only signature that actually validates the display ID (returns 1001 for bogus IDs) is the one above.
- `SLSCompleteDisplayConfiguration` fails with 1001 if the transaction contains no valid ops, which is exactly what the no-op setEnabled produces — misleading.
- A disabled display stops appearing in `SLSGetOnlineDisplayList` entirely, so `on` needs the state file to remember what it disabled.
- Replug or reboot re-detects a disabled display; the disable is session-scoped, not permanent.

## Notes

- No permissions, no daemon, no launchd — plain CLI, installs to `~/.local/bin`.
- Relies on private APIs; expect breakage on major macOS updates. If it segfaults, the signatures above probably moved — the permutation-probe approach in this README is how to re-derive them.
