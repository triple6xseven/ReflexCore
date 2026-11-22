// ReflexCore 0.7.0 VISION-LOOP PREVIEW3 — intentionally narrow Windows Notepad bridge.
// Images stay in memory. All keyboard input needs explicit human opt-in in the caller.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace ReflexCore.VisionLoop
{
    public static class Host
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder result, int capacity);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct Point { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] private struct KeyInput { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int dx,dy; public uint data,flags,time; public IntPtr extra; }
        [StructLayout(LayoutKind.Explicit)] private struct InputUnion
        {
            [FieldOffset(0)] public KeyInput key;
            [FieldOffset(0)] public MouseInput mouse;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Input { public uint type; public InputUnion data; }
        private const uint KeyUp=2;

        public static bool IsValidWindowToken(string token)
        {
            if (String.IsNullOrEmpty(token) || token.Length > 80) return false;
            foreach (char c in token)
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'))
                    return false;
            return true;
        }
        private static bool Allowed(IntPtr hwnd, string token)
        {
            if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd) || IsIconic(hwnd)) return false;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == 0) return false;
            try
            {
                using (Process p=Process.GetProcessById((int)pid))
                    if (!String.Equals(p.ProcessName,"notepad",StringComparison.OrdinalIgnoreCase)) return false;
                if (!String.IsNullOrEmpty(token))
                {
                    StringBuilder title=new StringBuilder(1024);
                    GetWindowText(hwnd,title,title.Capacity);
                    if (title.ToString().IndexOf(token,StringComparison.OrdinalIgnoreCase) < 0) return false;
                }
                return true;
            }
            catch { return false; }
        }
        public static bool IsForeground(string token) { return Allowed(GetForegroundWindow(),token); }
        public static bool ActivateNewDemoWindow(string token, int timeoutMs)
        {
            if (!IsValidWindowToken(token) || timeoutMs < 100 || timeoutMs > 30000) return false;
            Stopwatch clock=Stopwatch.StartNew();
            do
            {
                IntPtr candidate=IntPtr.Zero;
                EnumWindows(delegate(IntPtr hwnd, IntPtr unused)
                {
                    if (Allowed(hwnd,token)) { candidate=hwnd; return false; }
                    return true;
                },IntPtr.Zero);
                if (candidate != IntPtr.Zero)
                {
                    ShowWindow(candidate,9); // SW_RESTORE; never minimize existing windows
                    SetForegroundWindow(candidate);
                    Thread.Sleep(120);
                    if (Allowed(GetForegroundWindow(),token)) return true;
                }
                Thread.Sleep(180);
            } while(clock.ElapsedMilliseconds < timeoutMs);
            return false;
        }
        // Secondary independent OS evidence. Never use this alone to authorize
        // arbitrary applications; Allowed() already verifies the exact foreground
        // notepad.exe process and the randomly generated title token.
        private static bool EditableCandidate(AutomationElement el, int expectedPid)
        {
            try
            {
                if(el == null || el.Current.ProcessId != expectedPid || !el.Current.IsEnabled || el.Current.IsOffscreen)
                    return false;
                ControlType ct=el.Current.ControlType;
                if(ct!=ControlType.Edit && ct!=ControlType.Document) return false;
                System.Windows.Rect rect=el.Current.BoundingRectangle;
                if(rect.Width < 140 || rect.Height < 48) return false;
                if(!el.Current.IsKeyboardFocusable) return false;
                object pattern;
                if(el.TryGetCurrentPattern(ValuePattern.Pattern,out pattern))
                    return !((ValuePattern)pattern).Current.IsReadOnly;
                return el.TryGetCurrentPattern(TextPattern.Pattern,out pattern);
            }
            catch { return false; }
        }
        public static bool ConfirmEditableForeground(string token)
        {
            if (!IsValidWindowToken(token)) return false;
            IntPtr hwnd=GetForegroundWindow();
            if(!Allowed(hwnd,token)) return false;
            uint pid;
            GetWindowThreadProcessId(hwnd,out pid);
            if(pid==0) return false;
            try
            {
                AutomationElement root=AutomationElement.FromHandle(hwnd);
                if(root==null || root.Current.ProcessId!=(int)pid) return false;
                AutomationElement focus=AutomationElement.FocusedElement;
                if(EditableCandidate(focus,(int)pid)) return IsForeground(token);
                Condition editors=new OrCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),
                    new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document));
                AutomationElementCollection matches=root.FindAll(TreeScope.Descendants,editors);
                int limit=Math.Min(128,matches.Count);
                for(int i=0;i<limit;i++)
                {
                    AutomationElement candidate=matches[i];
                    if(!EditableCandidate(candidate,(int)pid)) continue;
                    // Focus only a verified editor within the exact owned Notepad window.
                    try { candidate.SetFocus(); } catch { continue; }
                    Thread.Sleep(80);
                    if(IsForeground(token) && EditableCandidate(AutomationElement.FocusedElement,(int)pid))
                        return true;
                }
                return false;
            }
            catch { return false; }
        }
        [DllImport("user32.dll")] private static extern bool IsChild(IntPtr parent, IntPtr child);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mode);

        private static AutomationElement OwnedEditor(string token)
        {
            if (!IsValidWindowToken(token)) throw new ArgumentException("Invalid demo token");
            var hwnd = GetForegroundWindow();
            if (!Allowed(hwnd, token)) throw new InvalidOperationException("Demo window lost focus");
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            var editor = AutomationElement.FocusedElement;
            if (!EditableCandidate(editor, (int)pid))
                throw new InvalidOperationException("Focus is outside the demo editor");
            var handle = new IntPtr(editor.Current.NativeWindowHandle);
            if (handle == IntPtr.Zero || !IsChild(hwnd, handle) || !Allowed(GetForegroundWindow(), token))
                throw new InvalidOperationException("Editor ownership could not be verified");
            return editor;
        }
        // EM_REPLACESEL is a system edit-control message. The window manager
        // marshals its UTF-16 string across processes. Timeout bounds a hung editor.
        [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr ReplaceSelection(IntPtr hwnd, uint message, IntPtr undo,
            string text, uint flags, uint timeout, out IntPtr result);
        private static void CheckModifiers()
        {
            foreach (int key in new int[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
                if (GetAsyncKeyState(key) < 0) throw new InvalidOperationException("Keyboard modifier is held");
        }
        private static Input Key(ushort vk, ushort scan, uint flags)
        {
            var item = new Input();
            item.type = 1;
            item.data.key = new KeyInput { vk = vk, scan = scan, flags = flags };
            return item;
        }
        private static void Batch(Input[] keys)
        {
            if (SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(Input))) != keys.Length)
                throw new InvalidOperationException("Windows did not accept the entire input batch");
        }
        private static void Shortcut(string token, ushort vk)
        {
            OwnedEditor(token);
            CheckModifiers();
            ushort ctrlScan = (ushort)MapVirtualKey(0x11, 0), scan = (ushort)MapVirtualKey(vk, 0);
            Batch(new Input[] {Key(0x11,ctrlScan,0),Key(vk,scan,0),Key(vk,scan,KeyUp),Key(0x11,ctrlScan,KeyUp)});
        }
        public static string EditorFamily(string token)
        {
            var name = OwnedEditor(token).Current.ClassName;
            if (name == "RichEditD2DPT") return "modern";
            if (String.Equals(name, "Edit", StringComparison.OrdinalIgnoreCase)) return "classic";
            return "unknown";
        }
        private static bool Matches(AutomationElement editor, string text)
        {
            object p;
            if (editor.TryGetCurrentPattern(ValuePattern.Pattern,out p))
                return String.Equals(((ValuePattern)p).Current.Value,text,StringComparison.Ordinal);
            if (!editor.TryGetCurrentPattern(TextPattern.Pattern,out p)) return false;
            string value = ((TextPattern)p).DocumentRange.GetText(text.Length + 3);
            return value == text || value == text + "\r" || value == text + "\r\n";
        }
        public static string EditAndSave(string token, string text, string preferred, Func<bool> stopped)
        {
            if (String.IsNullOrEmpty(text) || text.Length > 1000 || stopped == null)
                throw new ArgumentException("Invalid edit request");
            var editor = OwnedEditor(token);
            if (!Matches(editor, "")) throw new InvalidOperationException("Demo editor must initially be empty");
            if (stopped()) throw new OperationCanceledException("Stopped by operator");
            CheckModifiers();
            object pattern;
            string method;
            if (preferred != "native" && editor.TryGetCurrentPattern(ValuePattern.Pattern,out pattern) &&
                !((ValuePattern)pattern).Current.IsReadOnly)
            {
                ((ValuePattern)pattern).SetValue(text);
                method = "value";
            }
            else
            {
                method = "native";
                if (EditorFamily(token) == "unknown") throw new InvalidOperationException("Unrecognized native editor");
                if (stopped()) throw new OperationCanceledException("Stopped by operator");
                var handle = new IntPtr(OwnedEditor(token).Current.NativeWindowHandle);
                IntPtr ignored;
                if (ReplaceSelection(handle, 0x00C2, new IntPtr(1), text, 2, 750, out ignored) == IntPtr.Zero)
                    throw new InvalidOperationException("Native edit did not complete");
            }
            for (int attempt=0; attempt<20; attempt++)
            {
                if (stopped()) throw new OperationCanceledException("Stopped by operator");
                if (Matches(OwnedEditor(token),text))
                {
                    Shortcut(token,0x53);
                    return method;
                }
                Thread.Sleep(30);
            }
            throw new InvalidOperationException("Editor text did not match before save");
        }
        public static void CloseVerifiedTab(string token)
        {
            Shortcut(token,0x57);
        }
        private static void RequireForeground(string token)
        {
            if (!IsForeground(token)) throw new InvalidOperationException("Notepad demo lost foreground focus; input blocked.");
        }
        public static byte[] CaptureJpeg(string token, int requestedWidth)
        {
            if (requestedWidth < 320 || requestedWidth > 1024) throw new ArgumentOutOfRangeException("requestedWidth");
            IntPtr hwnd=GetForegroundWindow();
            if (!Allowed(hwnd,token)) throw new InvalidOperationException("Only a foreground Notepad window is permitted for VisionLoop preview.");
            // Capture the full visible window, including title/tab chrome. Client-only
            // captures caused the small VLM to miss the app identity entirely.
            Rect rect;
            if (!GetWindowRect(hwnd,out rect)) throw new InvalidOperationException("Could not locate window bounds.");
            Point origin=new Point {x=rect.left,y=rect.top};
            int w=rect.right-rect.left, h=rect.bottom-rect.top;
            if (w < 200 || h < 120 || w > 8192 || h > 8192) throw new InvalidOperationException("Window dimensions rejected.");
            using(Bitmap source=new Bitmap(w,h,PixelFormat.Format24bppRgb))
            {
                using(Graphics g=Graphics.FromImage(source)) g.CopyFromScreen(origin.x,origin.y,0,0,new Size(w,h),CopyPixelOperation.SourceCopy);
                RequireForeground(token);
                int targetW=Math.Min(requestedWidth,w);
                int targetH=Math.Max(1,(int)Math.Round((double)h*targetW/w));
                using(Bitmap scaled=new Bitmap(targetW,targetH,PixelFormat.Format24bppRgb))
                {
                    using(Graphics g=Graphics.FromImage(scaled))
                    {
                        g.InterpolationMode=InterpolationMode.HighQualityBilinear;
                        g.DrawImage(source,0,0,targetW,targetH);
                    }
                    int black=0,count=0;
                    for(int y=0;y<targetH;y+=Math.Max(1,targetH/18))
                    for(int x=0;x<targetW;x+=Math.Max(1,targetW/18))
                    {
                        Color c=scaled.GetPixel(x,y);count++;
                        if(c.R<8 && c.G<8 && c.B<8) black++;
                    }
                    if (count>0 && black*100>count*97) throw new InvalidOperationException("Mostly black screenshot rejected.");
                    using(MemoryStream data=new MemoryStream())
                    {
                        ImageCodecInfo codec=null;
                        foreach(ImageCodecInfo enc in ImageCodecInfo.GetImageEncoders())
                            if (enc.MimeType == "image/jpeg") {codec=enc;break;}
                        if(codec==null)throw new InvalidOperationException("JPEG encoder unavailable.");
                        using(EncoderParameters options=new EncoderParameters(1))
                        {
                            options.Param[0]=new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,70L);
                            scaled.Save(data,codec,options);
                        }
                        return data.ToArray();
                    }
                }
            }
        }
        public static byte[] SyntheticColorJpeg(bool red)
        {
            using(Bitmap image=new Bitmap(320,192,PixelFormat.Format24bppRgb))
            {
                using(Graphics g=Graphics.FromImage(image))
                {
                    g.Clear(red ? Color.FromArgb(220,25,25) : Color.FromArgb(25,65,225));
                    using(Brush b=new SolidBrush(Color.White))g.FillRectangle(b,110,68,100,56);
                }
                using(MemoryStream ms=new MemoryStream()) {image.Save(ms,ImageFormat.Jpeg);return ms.ToArray();}
            }
        }
        public static void SelfTest()
        {
            if(!IsValidWindowToken("ReflexCore-VisionLoop-2f3a.txt") || IsValidWindowToken("bad\\path") || IsValidWindowToken(""))
                throw new Exception("Window title guard failed.");
            int required=IntPtr.Size==8 ? 40 : 28;
            if(Marshal.SizeOf(typeof(Input))!=required)throw new Exception("SendInput layout mismatch.");
            if(SyntheticColorJpeg(true).Length<500 || SyntheticColorJpeg(false).Length<500)throw new Exception("Synthetic JPEG creation failed.");
            Console.WriteLine("[ReflexCore] VisionHost C# guards, input layout, synthetic JPEG: PASS (no screen/input used).");
        }
    }
}
