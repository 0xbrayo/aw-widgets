# AW Widgets

Native macOS **WidgetKit** extension that shows **screen time per ActivityWatch category**.

Categories and rules come from your AW settings (`GET /api/0/settings` → `classes`). Time is queried from window events, AFK-filtered, then categorized with the same Query2 `categorize()` path the web UI uses.

## Requirements

- macOS 14+
- [ActivityWatch](https://activitywatch.net) running locally (`http://127.0.0.1:5600`)
- Xcode 16+ (and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`)

## Quick start

```bash
# Generate the Xcode project (after editing project.yml)
xcodegen generate

# Build
xcodebuild -scheme AWWidgets -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

# Install and run so macOS discovers the widget extension
make run
```

Or open `AWWidgets.xcodeproj` in Xcode and Run (`⌘R`).

## Install a release

1. Download `AWWidgets-macos-universal.zip` from the latest [GitHub release](../../releases/latest).
2. Unzip it and move `AWWidgets.app` to `/Applications`.
3. Open the app once, then add **AW Categories** from Notification Center's **Edit Widgets** screen.
4. The release is not notarized. On first launch, Control-click `AWWidgets.app`, choose **Open**, then confirm **Open**.

Create a release by pushing a version tag such as `v0.1.0`; GitHub Actions builds and attaches the universal macOS archive.

### Add the widget

1. Run `make run` to install **AWWidgets** in `/Applications` and register the extension. It runs in the background with no menu bar or Dock icon.
2. Right-click the desktop / Notification Center → **Edit Widgets**.
3. Search for **AW Categories**.
4. Add Small / Medium / Large.
5. Long-press the widget → **Edit Widget** to switch **Today / Yesterday / This Week**.

## What you get

| Surface | Behavior |
|--------|----------|
| **Widget** | Glanceable totals + colored category list; configurable time range |

## Architecture

```
ActivityWatch (localhost:5600)
        │
        ▼
  WidgetKit extension (queries AW and caches snapshots)
        │
        ▼
  ~/Library/Application Support/aw-widgets/
```

Shared code lives in `Shared/`:

- `AWClient.swift` — REST + Query2 category summary
- `Models.swift` — time ranges, snapshot models, colors
- `SharedStore.swift` — snapshot files + widget reload

## Configuration

The widget connects to ActivityWatch at `127.0.0.1:5600`. Categories are edited in ActivityWatch → **Settings → Categorization**.

## Development notes

- The widget is sandboxed and has network-client access to reach `localhost`.
- Snapshots are stored in the widget extension's Application Support container.

## License

MIT (or match your preference).
