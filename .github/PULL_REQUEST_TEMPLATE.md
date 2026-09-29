<!--
Thanks for contributing to Mac Performance Monitor. Please fill out the sections below.
Avoid em and en dashes in prose and code comments (see CONTRIBUTING.md).
-->

## Summary

<!-- What does this change do, and why? -->

## Related issue

<!-- e.g. Closes #123 -->

## How verified

<!-- Tests added or run, manual steps, screenshots for UI changes. -->

## Checklist

- [ ] `swift test` passes
- [ ] `swift format lint --strict --recursive Sources Tests Package.swift` passes
- [ ] `CHANGELOG.md` updated under "Unreleased" for any user-visible change
- [ ] Relevant docs, upgrade notes, and screenshots match the change
- [ ] New UI strings pass source/compiler coverage and String Catalog compilation
- [ ] No usage telemetry or upload of recorded history introduced
- [ ] Any new network access, permissions, or exported data are documented
- [ ] Data-layer changes keep `MacPerfMonitorCore` free of SwiftUI
