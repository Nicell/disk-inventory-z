# Building Disk Inventory Z

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15.x

## Build from source

```sh
git clone https://github.com/Nicell/disk-inventory-z.git
cd disk-inventory-z
xcodebuild -project "Disk Inventory Z.xcodeproj" \
           -scheme "Disk Inventory Z" \
           -configuration Release build
```

The build product lands at `build/Release/Disk Inventory Z.app`.

For a quick debug build you can drop `-configuration Release` (the default
is Debug, which writes to `build/Debug/`).

## Project layout

Everything the Xcode target builds lives under `src/`; the repository root
holds only docs, the project file, and CI config.

| Path                 | Contents                                                        |
| -------------------- | --------------------------------------------------------------- |
| `src/Source/`        | Application Objective-C sources                                 |
| `src/Resources/`     | Images, toolbar definition, and other bundled assets            |
| `src/Vendor/`        | Third-party / derived code (OmniAppKit shims, CocoaTech helpers)|
| `src/TreeMapView/`   | The folded-in treemap rendering sources                         |
| `src/*.lproj/`       | Localized nibs and strings (en, de, es, fr)                     |
| `src/Images.xcassets`| App icon and asset catalog                                      |
| `src/Info.plist`     | App bundle configuration and entitlements                       |
| `scripts/`           | Build and maintenance scripts                                   |
| `docs/`              | Developer notes and reference material                          |

## Releases

Tagged builds (`v*`) run [`.github/workflows/release.yml`](.github/workflows/release.yml)
on macOS. The workflow attaches a `.dmg` to the GitHub release. A tag with a hyphen, like
`v2.1.0-beta.1`, becomes a pre-release.

How the app gets signed depends on the repository's Actions secrets:

| Secrets | Result |
| ------- | ------ |
| None | Ad-hoc signed. Runs, but macOS blocks the first launch of a downloaded copy until it's allowed in System Settings. |
| `BUILD_CERT_P12_BASE64`, `BUILD_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID` | Signed with your Developer ID certificate. |
| The above plus `APPLE_ID`, `APPLE_APP_PASSWORD` | Also notarized and stapled, so it opens with no warnings. |

A Developer ID certificate requires a paid Apple Developer Program membership.
An Apple Development certificate can't sign apps for distribution.

To cut a release, push a tag:

```sh
git tag v2.1.0
git push origin v2.1.0
```

## Lineage

Disk Inventory Z is a fork of
[Disk Inventory X](https://gitlab.com/tderlien/disk-inventory-x) by
Tjark Derlien. Notable structural changes from upstream:

- Removed the OmniAppKit / OmniFoundation / OmniBase dependencies (the
  original framework set is no longer maintained for current macOS / Xcode).
- Folded the standalone
  [`treemapview-framework`](https://gitlab.com/tderlien/treemapview-framework)
  sources directly into the app target — one repo, one build, no embedded
  framework.
- macOS 13+ targeting, hardened runtime, Developer ID signing, and
  notarization driven by GitHub Actions.
