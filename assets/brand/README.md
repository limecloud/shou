# Shou identity

English product name: **Shou**. Chinese display name: **收拾一下**.

**Tidy up. That's it. / 收好，就好。**

The native icon is an original smiling jade storage box with an ivory lid and a coral tab. Its bold silhouette and simple face represent a friendly organizing companion. Artwork contains no text and stays language independent. The pale mint tile matches the workspace palette.

The canonical icon raster master is [shou-mascot-source.png](shou-mascot-source.png). The transparent [shou-mascot.png](shou-mascot.png) uses the same character for the home illustration. [generate-app-icon.swift](../../scripts/generate-app-icon.swift) applies the native rounded mask, margin and shadow and exports all icon sizes. Rebuild on macOS without extra dependencies:

```sh
swift "scripts/generate-app-icon.swift"
python3 "scripts/generate-windows-resources.py"
```

`Shou.icns` contains the native 16, 32, 128, 256 and 512 pt representations at 1× and 2×. Windows `Generated/Shou.ico` embeds the exact 16, 32, 128 and 256 px PNG bytes from this iconset. `shou-icon-1024.png` is the full-size preview; `shou-icon.pdf` embeds raster artwork and is not a vector master. The application bundle declares `CFBundleIconFile=Shou`, and packaging verifies the shipped artwork against these resources.

The [generation record](generation.md) and [prompt](shou-mascot.prompt.txt) describe the image-generation method and final preparation. Keep the canonical PNG in the repository; rebuilding native icons never calls a network service.

Both platforms display the coordinated [task illustration family](../design/illustrations/README.md) on initial pages and the app icon beside the version in Settings → About Shou. The family uses this mascot as its reference. Result lists retain their working space. Brand artwork is decorative and introduces no action or animation. Windows copies the mascot, icon and task PNGs through the shared resource generator; Mac packaging verifies the mascot, every task image and ICNS.

The [website kit](web/README.md) reserves transparent symbols, light/dark horizontal wordmarks, browser/mobile icons and optimized task illustrations for the future marketing site. These are offline derivatives of the same approved originals; there is no website implementation or runtime generation dependency.

新标识采用原创的青绿笑脸收纳盒、奶油色盒盖和珊瑚色拉扣。母版为位图；Mac ICNS 与 Windows ICO 均从同一母版生成。各页初始插画沿用同一角色，设置“关于 Shou”在版本旁展示应用图标，系统入口使用同款标识。内容导航不重复品牌区，结果列表保留工作空间。官网预留透明标识、浅深字标、浏览器及移动图标与主题插画，见上述素材包。生成方式与提示词见上述记录，密钥不属于项目资源。
