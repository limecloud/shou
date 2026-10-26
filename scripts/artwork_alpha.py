"""Offline alpha preparation shared by Shou's brand and task artwork importers."""


def smooth_alpha(image, contour_radius):
    from PIL import ImageFilter

    alpha = image.getchannel('A').point(lambda value: max(0, min(255, round((value - 230) * 255 / 18))))
    alpha = alpha.filter(ImageFilter.MedianFilter(15)).filter(ImageFilter.MinFilter(3))
    # Smooth the silhouette, then rebuild a narrow antialiased edge. RGB detail
    # stays untouched; blurring the full image would soften the face/material.
    alpha = alpha.filter(ImageFilter.GaussianBlur(contour_radius))
    return alpha.point(lambda value: 255 if value >= 128 else 0).filter(ImageFilter.GaussianBlur(0.85))
