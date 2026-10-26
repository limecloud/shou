# Shou mascot generation / 标识生成记录

Date / 日期：2026-10-26。

The user requested a cute, tangible, original brand companion and supplied an image-generation endpoint. The image was generated with the installed **imagegen fallback CLI**, requesting `gpt-image-2`, high quality and `1024x1024`. The endpoint returned a 1254 × 1254 RGBA image; its upstream model identity was not independently verified. There were no supplied reference images or copied brand assets. Credentials were passed only to the generation process and are not stored here.

- Final prompt / 完整提示词：[shou-mascot.prompt.txt](shou-mascot.prompt.txt).
- Canonical 1024 px raster master / 位图母版：[shou-mascot-source.png](shou-mascot-source.png).
- Transparent home mascot / 首页透明吉祥物：[shou-mascot.png](shou-mascot.png).
- Native app preview / 应用图标预览：[shou-icon-1024.png](shou-icon-1024.png).
- Parameters, preparation and SHA256 / 参数、后处理及摘要：[generation.json](generation.json).
- Original API response remains in the local workspace at `output/imagegen/shou-storage-buddy.png`; native builds depend only on the canonical master above.

The returned alpha contained a noisy, diffuse background. [prepare-brand-artwork.py](../../scripts/prepare-brand-artwork.py) remaps alpha, removes fragments, smooths the contour with a 14 px Gaussian/128 threshold and rebuilds a 0.85 px antialiased edge at original resolution. RGB material detail is unchanged. It resizes with Lanczos and composites the mascot over an ivory-to-mint gradient with a subtle grounding shadow. These are offline image-processing steps, not additional model calls. The native generator adds the app tile mask and outer shadow, then exports all Mac sizes; the Windows resource generator embeds those same PNG bytes into ICO. The PDF contains raster artwork, not editable vector paths.

设计取电商品牌的简洁轮廓、表情性格与小尺寸识别思路，采用原创收纳盒形象：青绿盒身、奶油色盒盖、珊瑚色拉扣和笑脸。没有文字、动物拟态或其他品牌标识。母版保存在仓库中，后续构建不依赖接口或密钥。小尺寸与实际系统入口的验收应分别记录；资源生成成功不等于 Windows 原生界面已经验收。

The ten [task illustrations](../design/illustrations/README.md) were generated separately through the same CLI edit workflow, with this canonical brand master as the reference. Their own prompts, response/master digests and preparation record remain beside the artwork. The [website kit](web/README.md) is an offline export of approved images, not another model request. Its wordmarks render the exact text `Shou` with a locally available rounded font; the kit records the font identity and digest without distributing the font file.

十页主题插画使用同一品牌母版作参考，分别保留提示词与生成记录；官网素材由这些批准资源离线导出。浅深字标的文字由本机圆体字体确定性排版，字体文件不随素材分发。后续构建与校验不需要接口密钥。
