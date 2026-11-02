# 8. Minimal-mode icon bloom

Status: implemented. The icon strip uses a pure geometry helper and passive AppKit pointer tracking, reuses entry thumbnails/actions, and exposes the persisted View menu toggle. The following sections retain the design and acceptance criteria.

## Confirmed outcome

In Minimal mode, icons enlarge smoothly around the pointer, with the closest icon growing most and neighboring icons growing less, like macOS Dock magnification. The user confirmed Dock-style magnification on hover as the intended behavior.

Propose a dedicated horizontal Minimal icon presentation with overflow scrolling. It shows the same filtered entries, sort order, selection, and actions as the main window. The normal saved display format remains unchanged when leaving Minimal mode. Add **View → Minimal Icon Bloom** to enable/disable this presentation; when disabled, Minimal retains its existing layout. Start enabled for the new presentation, with a modest default maximum magnification of 1.6×.

## Design and integration

Add `MinimalIconView.swift` and a pure `IconBloomLayout` geometry helper. In `ContentView.detailContent`, route populated results to the new view when Minimal and bloom are enabled, before the normal table/list/card branches. Reuse `EntryThumbnail`, selection, context-menu, open/reveal, accessibility, and hover-information behavior rather than building alternate entry actions.

Track pointer location in one stable local coordinate space. Derive each icon’s influence from distance to its untransformed center, using a smooth compact curve such as `w = (1 - (d / radius)^2)^2` within the radius and zero outside. Scale is `1 + strength * w`. Start with a radius around two base icon widths, then tune by visual testing.

Compute growth and neighbor displacement together so enlarged icons do not overlap. Base-center measurement and pointer tracking must not depend recursively on transformed frames. Reserve edge space, define a single hit-testing policy using the displayed frames, and keep keyboard/VoiceOver order tied to entry order. Cache geometry and update only visible icons and nearby neighbors.

Use supported SwiftUI hover tracking, or an AppKit tracking view if profiling requires it. References: [continuous hover](https://developer.apple.com/documentation/swiftui/view/oncontinuoushover(coordinatespace:perform:)) and [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion). Confirm API availability against macOS 14.4 during implementation.

## Small-window and interaction constraints

- Preserve the current minimum content height of `320 / 3` points. Calculate available height after any visible navigation/filter UI and shrink base size/magnification accordingly; never increase the window minimum to accommodate animation.
- If vertical room cannot accommodate growth, use static icons with a clear focused/hovered outline. Keep overflow reachable through horizontal scrolling and keyboard navigation.
- Anchor growth consistently and retain edge padding so the first/last icons do not clip. Geometry updates must not shift scroll position unexpectedly.
- Reuse loaded previews; pointer movement must not restart Quick Look requests or save library/preferences.
- Suspend/reset bloom on pointer exit, menu opening, scrolling, drag/drop, window deactivation, filtering, and mode changes. Coordinate hover-info delay so a popup does not intercept movement between icons.
- Preserve single/double-click opening and modifier-key multiselection. Enlargement never opens an item by itself.
- With Reduce Motion enabled, use a static focus treatment without neighbor displacement. Every action remains available without hover.

## Implementation sequence

1. Prototype static icon-strip layout and shared interaction extraction; verify small-height fit.
2. Implement/test distance weighting, displacement, boundary clamps, and displayed-frame hit testing.
3. Add eased hover transitions, preview reuse, scrolling, and menu/focus lifecycle handling.
4. Add the persisted toggle, accessibility fallback, and final visual/performance tuning.

## Acceptance and validation

- Pointer movement smoothly enlarges the nearest icon and tapers neighboring growth without jitter or overlap.
- Clicking the displayed enlarged icon always selects/opens that entry, including at boundaries and during animation.
- Check short/wide windows, the current minimum height, 48–160 point thumbnail settings, first/last items, overflow, and mixed file/folder/URL previews.
- Check quick pointer crossings, rapid filter changes, missing files, drag/drop, context menus, modifier selection, keyboard navigation, VoiceOver, and Reduce Motion.
- Test geometry deterministically; manually inspect both appearances at 1×/2× display scale. Profile a synthetic 1,000-entry library with only visible items rendered; target smooth 60 Hz interaction on documented hardware.
- Toggling Minimal restores the prior normal display format; disabling bloom restores current Minimal behavior. No original file or entry metadata changes.

This feature can proceed independently of the other seven plans. Do not use private Dock animation APIs.

## Implementation validation

The full XCTest suite passes with 33 tests, including eight bloom tests covering falloff, non-overlap and boundary padding, short heights and thumbnail sizes, Reduce Motion geometry, displayed-frame hit testing, native coordinate conversion, and 1,000-entry geometry/visible-tile rendering. The release app builds successfully. Running-app checks cover pointer magnification, neighboring displacement, the short Minimal window, modifier selection, keyboard navigation, the menu toggle, and preference restoration after relaunch. The geometry benchmark is not an end-to-end animation frame-rate measurement; 60 Hz profiling and visual checks on additional display scales remain release follow-ups.
