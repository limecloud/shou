# Shou identity

English product name: **Shou**. Chinese display name: **收拾一下**.

**Tidy up. That's it. / 收好，就好。**

The native icon uses a warm folded container on a light ceramic tile. It represents gathering items into place. Artwork contains no text and stays language independent.

The editable vector master is [generate-app-icon.swift](../../scripts/generate-app-icon.swift). Rebuild on macOS without extra dependencies:

```sh
swift "scripts/generate-app-icon.swift"
```

`Shou.icns` contains the native 16, 32, 128, 256 and 512 pt representations at 1× and 2×. `shou-icon-1024.png` is the full-size preview; `shou-icon.pdf` is the vector export. The application bundle declares `CFBundleIconFile=Shou`, and packaging verifies the shipped artwork against these resources.
