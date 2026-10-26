# Shou task illustrations / 页面插画

Ten transparent task illustrations share Shou's original jade storage-box mascot, ivory lid, coral tab, soft 3D material and studio lighting. Each task has its own supporting objects. These are decorative images; they express neither measured storage nor deletion eligibility.

十个主题为 `cleanup`、`applications`、`projects`、`space`、`large-files`、`privacy`、`startup`、`rules`、`history`、`settings`。初始页使用大插画；已有结果时保留列表空间，规则、历史与设置使用紧凑插画标题。

| Location / 路径 | Purpose / 用途 |
| --- | --- |
| [source/](source/) | Approved transparent raster masters / 批准的透明位图母版 |
| [prompts/](prompts/) | Complete prompt for each task / 各主题完整提示词 |
| [generation.json](generation.json) | Generation parameters, reference, preparation and response/master SHA256 / 参数、参考、处理与摘要 |
| [manifest.json](manifest.json) | Offline exporter inputs and runtime PNG hashes / 离线导出源及运行时摘要 |
| `<task>.png` | Canonical runtime PNG; identical bytes on Mac and Windows / 双端同源运行资源 |

Generated on 2026-10-26 using the installed imagegen **fallback CLI edit** workflow, requesting `gpt-image-2`, high quality, `1024x1024`, with [the brand master](../../brand/shou-mascot-source.png) as the reference. The endpoint returned 1254 × 1254 RGBA images; upstream model identity was not independently verified. Original responses remain locally under `output/imagegen/workspace/`; builds depend only on approved resources here. Credentials are not stored.

The exact reference used during generation is retained as [source/reference.png](source/reference.png), before subsequent brand-edge refinement. The explicit import cleans noisy alpha edges, smooths the contour with a 6 px Gaussian/128 threshold, rebuilds a 0.85 px antialiased edge without changing RGB detail, crops the subject and retains a transparent margin. [generation.json](generation.json) records the exact preparation. Normal exports use AppKit offline and require no model service or Pillow:

```sh
python3 "scripts/workspace_artwork.py"
python3 "scripts/generate-windows-resources.py"
python3 "scripts/workspace_artwork.py" --check
python3 "scripts/generate-windows-resources.py" --check
```

For approved new responses, `workspace_artwork.py --import-generated <directory>` additionally requires Pillow and matching `prompts/<task>.txt`. It updates the masters and records before offline export. Do not edit generated platform copies. Mac packaging verifies these sources and every bundled image. Website WebP derivatives live in the [website kit](../../brand/web/README.md).

重新生图时以本仓库品牌母版锁定角色、配色、材质和光线，保留完整提示词及摘要，检查浅深背景边缘与实际页面重心。资源通过校验不代表原生 Windows 界面已验收。
