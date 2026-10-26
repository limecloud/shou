# Website brand kit / 官网品牌素材

Reserved assets for Shou's future marketing website, exported offline from the same approved brand and task images used by the native applications. No website is implemented by this package.

为未来宣传官网预留的同源素材，统一青绿收纳盒、奶油色盒盖、珊瑚点缀和柔和立体材质。透明图片适合叠放在网站背景上，浅深版字标按承载背景选择。

| Asset / 资源 | Usage / 用途 |
| --- | --- |
| `logo-symbol.png` / `.webp` | Transparent standalone mascot / 透明独立标识 |
| `logo-horizontal-light.png` / `.webp` | Dark `Shou` text for a light surface / 浅色背景横版字标 |
| `logo-horizontal-dark.png` / `.webp` | Light `Shou` text for a dark surface / 深色背景横版字标 |
| `favicon.ico`, `favicon-16.png`, `favicon-32.png` | Browser tabs / 浏览器标签页 |
| `apple-touch-icon.png` | 180 px Apple Touch Icon |
| `icon-192.png`, `icon-512.png` | Square web/app icon tiles / 网站及应用图标 |
| `illustrations/<task>.webp` | All ten task illustrations with transparency / 十页主题透明插画 |
| [manifest.json](manifest.json) | Source/output SHA256 and local wordmark font identity / 来源、输出摘要与字标字体记录 |

PNG and logo WebP variants are lossless; task WebP images use quality 92 with alpha. These are raster assets, not editable vector masters. See the [brand generation record](../generation.md) and [task prompts](../../design/illustrations/prompts/).

```sh
# Export requires Pillow and a locally available rounded bold TTF.
python3 "scripts/export-web-brand.py"
# Verification uses the Python standard library; no font or network is required.
python3 "scripts/export-web-brand.py" --check
```

On macOS, export defaults to the local Arial Rounded Bold font; `--font <path>` selects an available alternative. The manifest records its name and file digest. The font file is neither downloaded nor distributed. Changing it changes the wordmark and requires visual review and a new manifest. Keep this package synchronized after changing approved brand images, illustrations, tokens or the exporter.

未来官网直接引用本目录导出资源；不要单独重画角色或改写生成副本。普通导出与校验均离线执行，不需要生图接口或密钥。宣传页面的文案、布局、发布与实际网站验收属于后续工作。
