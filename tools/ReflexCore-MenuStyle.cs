using System.Drawing;
using System.Windows.Forms;

namespace ReflexCore.Presentation
{
    internal sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        private sealed class Colors : ProfessionalColorTable
        {
            private readonly Color surface, highlight, outline;
            public Colors(Color surface, Color highlight, Color outline)
            {this.surface=surface;this.highlight=highlight;this.outline=outline;UseSystemColors=false;}
            public override Color ToolStripDropDownBackground {get{return surface;}}
            public override Color ImageMarginGradientBegin {get{return surface;}}
            public override Color ImageMarginGradientMiddle {get{return surface;}}
            public override Color ImageMarginGradientEnd {get{return surface;}}
            public override Color MenuItemSelected {get{return highlight;}}
            public override Color MenuItemBorder {get{return highlight;}}
            public override Color MenuBorder {get{return outline;}}
            public override Color SeparatorDark {get{return outline;}}
            public override Color SeparatorLight {get{return surface;}}
            public override Color CheckBackground {get{return highlight;}}
            public override Color CheckSelectedBackground {get{return highlight;}}
            public override Color CheckPressedBackground {get{return highlight;}}
        }
        private readonly Color text;
        internal DarkMenuRenderer(Color surface,Color highlight,Color outline,Color text)
            :base(new Colors(surface,highlight,outline)){this.text=text;RoundedEdges=false;}
        internal static DarkMenuRenderer ForTray()
        {
            return new DarkMenuRenderer(Color.FromArgb(31,31,34),Color.FromArgb(62,56,72),
                Color.FromArgb(77,73,82),Color.FromArgb(247,240,252));
        }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor=e.Item.Enabled?text:Color.FromArgb(155,151,162);
            base.OnRenderItemText(e);
        }
        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            e.ArrowColor=text;
            base.OnRenderArrow(e);
        }
    }
}
