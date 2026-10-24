using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

/// <summary>Product vectors follow the Mac decorative loop, independently of measured work.</summary>
internal sealed class OperationActivityArtwork : Canvas
{
    private readonly FrameworkElement[] particles = new FrameworkElement[OperationArtworkMotion.ParticleCount];
    private readonly CompositeTransform[] transforms = new CompositeTransform[OperationArtworkMotion.ParticleCount];
    private readonly Ellipse pulse;
    private readonly ContentControl intake;
    private string symbol = "";

    public OperationActivityArtwork()
    {
        Width = (double)Application.Current.Resources["ShouCleanupArtworkWidth"];
        Height = (double)Application.Current.Resources["ShouCleanupArtworkHeight"];
        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        var accent = (Brush)Application.Current.Resources["ShouAccentBrush"];
        AddEllipse(Width * 0.61, Width * 0.61, 0, accent, 0.035);
        AddEllipse(Width * 0.48, Width * 0.48, 0, accent, 0.06, outline: true);
        // Overlapping translucent contours soften the ambient shadow without a bitmap asset.
        for (var index = 4; index >= 0; index--)
            AddEllipse(Width * (0.58 + index * 0.025), Width * (0.14 + index * 0.025), Width * 0.17, accent, 0.012);
        for (var index = 0; index < particles.Length; index++)
        {
            var particle = ProductIcon.Create(index % 3 == 0 ? "document" : "document-text", Width * 0.095);
            particle.RenderTransformOrigin = new(0.5, 0.5);
            particle.RenderTransform = transforms[index] = new CompositeTransform();
            Canvas.SetLeft(particle, (Width - particle.Width) / 2);
            Canvas.SetTop(particle, (Height - particle.Height) / 2);
            AutomationProperties.SetAccessibilityView(particle, AccessibilityView.Raw);
            Children.Add(particles[index] = particle);
        }
        AddEllipse(Width * 0.37, Width * 0.075, Width * 0.115, accent, 0.1);
        intake = new() { Width = Width * 0.23, Height = Width * 0.23, IsHitTestVisible = false };
        Canvas.SetLeft(intake, (Width - intake.Width) / 2);
        Canvas.SetTop(intake, (Height - intake.Height) / 2 + Width * 0.13);
        AutomationProperties.SetAccessibilityView(intake, AccessibilityView.Raw);
        Children.Add(intake);
        pulse = AddEllipse(Width * 0.56, Width * 0.15, Width * 0.165, accent, 0.12, outline: true);
        SetSymbol("cleanup");
        Draw(0.35, paused: true);
    }

    public void SetSymbol(string value)
    {
        if (symbol == value) return;
        symbol = value;
        var icon = ProductIcon.Create(value == "cleanup" ? "intake" : value, Width * 0.23);
        AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
        intake.Content = icon;
    }

    public void Draw(double phase, bool paused)
    {
        for (var index = 0; index < particles.Length; index++)
        {
            var value = OperationArtworkMotion.Particle(index, phase, Width, paused);
            var transform = transforms[index];
            transform.TranslateX = value.X; transform.TranslateY = value.Y;
            transform.ScaleX = transform.ScaleY = value.Scale; transform.Rotation = value.Rotation;
            particles[index].Opacity = value.Opacity * value.InkOpacity;
        }
        pulse.Opacity = OperationArtworkMotion.PulseOpacity(phase, paused);
    }

    private Ellipse AddEllipse(double width, double height, double y, Brush brush, double opacity, bool outline = false)
    {
        var ellipse = new Ellipse { Width = width, Height = height, Opacity = opacity, IsHitTestVisible = false };
        if (outline) { ellipse.Stroke = brush; ellipse.StrokeThickness = 1; }
        else ellipse.Fill = brush;
        AutomationProperties.SetAccessibilityView(ellipse, AccessibilityView.Raw);
        Canvas.SetLeft(ellipse, (Width - width) / 2); Canvas.SetTop(ellipse, (Height - height) / 2 + y);
        Children.Add(ellipse);
        return ellipse;
    }
}
