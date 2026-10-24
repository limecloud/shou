namespace Shou.Windows.Presentation;

public readonly record struct OperationArtworkParticle(double X, double Y, double Scale, double Rotation,
    double Opacity, double InkOpacity, bool HasText);

/// <summary>Decorative geometry matches the Mac artwork, never measured completion or deleted items.</summary>
public static class OperationArtworkMotion
{
    public const int ParticleCount = 7;

    public static OperationArtworkParticle Particle(int index, double phase, double width, bool paused = false)
    {
        if (index is < 0 or >= ParticleCount) throw new ArgumentOutOfRangeException(nameof(index));
        if (!double.IsFinite(width) || width <= 0) throw new ArgumentOutOfRangeException(nameof(width));
        var progress = Normalize(phase + (double)index / ParticleCount);
        var travel = progress * progress;
        var side = index % 2 == 0 ? -1d : 1d;
        var originX = side * (0.27 + index % 3 * 0.065);
        var originY = -0.24 + index % 3 * 0.05;
        var opacity = Math.Min(1, progress / 0.12) * Math.Max(0, 1 - Math.Max(0, progress - 0.7) / 0.3);
        return new(width * (originX * (1 - travel) + side * Math.Sin(progress * Math.PI) * 0.035),
            width * (originY * (1 - travel) + 0.11 * travel), 1 - travel * 0.82, side * (18 - travel * 40),
            paused ? 0 : opacity, index % 2 == 0 ? 0.5 : 0.28, index % 3 != 0);
    }

    public static double PulseOpacity(double phase, bool paused = false) => paused ? 0.12 : 0.12 + 0.1 * Math.Sin(Normalize(phase) * 2 * Math.PI);

    private static double Normalize(double phase)
    {
        if (!double.IsFinite(phase)) throw new ArgumentOutOfRangeException(nameof(phase));
        return (phase % 1 + 1) % 1;
    }
}
