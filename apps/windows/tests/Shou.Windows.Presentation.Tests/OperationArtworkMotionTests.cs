using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class OperationArtworkMotionTests
{
    [Fact]
    public void KnownMacKeyframesKeepTheirGeometryAndDoNotExpressCompletion()
    {
        var start = OperationArtworkMotion.Particle(0, 0, 300);
        Assert.Equal(-81, start.X, 10); Assert.Equal(-72, start.Y, 10);
        Assert.Equal(1, start.Scale); Assert.Equal(-18, start.Rotation); Assert.Equal(0, start.Opacity);
        Assert.False(start.HasText); Assert.Equal(0.5, start.InkOpacity);
        var middle = OperationArtworkMotion.Particle(0, 0.5, 300);
        Assert.Equal(-71.25, middle.X, 10); Assert.Equal(-45.75, middle.Y, 10);
        Assert.Equal(0.795, middle.Scale, 10); Assert.Equal(-8, middle.Rotation, 10); Assert.Equal(1, middle.Opacity);
        Assert.Equal(0.5, OperationArtworkMotion.Particle(0, 0.85, 300).Opacity, 10);
    }
    [Theory]
    [InlineData(-1d)]
    [InlineData(0d)]
    [InlineData(0.35)]
    [InlineData(0.7)]
    [InlineData(0.999)]
    [InlineData(9d)]
    public void AllSevenParticlesStayBoundedAcrossTheLoop(double phase)
    {
        for (var index = 0; index < OperationArtworkMotion.ParticleCount; index++)
        {
            var frame = OperationArtworkMotion.Particle(index, phase, 300);
            Assert.InRange(frame.Opacity, 0, 1); Assert.InRange(frame.Scale, 0.18, 1);
            Assert.InRange(frame.X, -130, 130); Assert.InRange(frame.Y, -72, 34);
            Assert.InRange(frame.Rotation, -22, 22); Assert.Equal(index % 3 != 0, frame.HasText);
            var repeat = OperationArtworkMotion.Particle(index, phase + 1, 300);
            Assert.Equal(frame.X, repeat.X, 9); Assert.Equal(frame.Y, repeat.Y, 9);
        }
        Assert.InRange(OperationArtworkMotion.PulseOpacity(phase), 0.02, 0.22);
    }
    [Fact]
    public void ReducedMotionAndStoppingHideTravelAndFreezeTheIntakePulse()
    {
        for (var index = 0; index < OperationArtworkMotion.ParticleCount; index++)
            Assert.Equal(0, OperationArtworkMotion.Particle(index, 0.35, 300, paused: true).Opacity);
        Assert.Equal(0.12, OperationArtworkMotion.PulseOpacity(0.35, paused: true));
    }
    [Fact]
    public void ScalingChangesOnlyCoordinates()
    {
        var full = OperationArtworkMotion.Particle(1, 0.35, 300);
        var half = OperationArtworkMotion.Particle(1, 0.35, 150);
        Assert.Equal(full.X / 2, half.X, 10); Assert.Equal(full.Y / 2, half.Y, 10);
        Assert.Equal(full.Scale, half.Scale); Assert.Equal(full.Rotation, half.Rotation); Assert.Equal(full.Opacity, half.Opacity);
    }
    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void InvalidPhasesAreRejected(double phase) => Assert.Throws<ArgumentOutOfRangeException>(() => OperationArtworkMotion.Particle(0, phase, 300));
}
