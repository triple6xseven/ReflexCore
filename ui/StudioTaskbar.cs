using System;
using System.IO;
using System.Runtime.InteropServices;

namespace ReflexCore.Studio;

static class StudioTaskbar
{
    static readonly Guid AppProperties = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey
    {
        internal Guid Format;
        internal uint Id;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PropertyValue
    {
        [FieldOffset(0)] internal ushort Type;
        [FieldOffset(8)] internal IntPtr Text;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        uint GetCount();
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropertyValue value);
        void SetValue(ref PropertyKey key, ref PropertyValue value);
        void Commit();
    }

    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    internal static void Register(IntPtr window, string projectRoot)
    {
        if (string.IsNullOrEmpty(projectRoot) || window == IntPtr.Zero) return;
        string launcher = Path.Combine(projectRoot, "ReflexCore.exe");
        if (!File.Exists(launcher)) return;

        IPropertyStore store = null;
        try
        {
            Guid iid = typeof(IPropertyStore).GUID;
            SHGetPropertyStoreForWindow(window, ref iid, out store);
            Set(2, "\"" + launcher + "\"");
            Set(3, launcher + ",0");
            Set(4, "ReflexCore Studio");
            Set(5, "ReflexCore.Studio");
            store.Commit();
        }
        catch (COMException error)
        {
            System.Diagnostics.Trace.TraceWarning("ReflexCore taskbar registration failed (0x{0:X8}).", error.ErrorCode);
        }
        finally
        {
            if (store != null) Marshal.ReleaseComObject(store);
        }

        void Set(uint id, string text)
        {
            var key = new PropertyKey { Format = AppProperties, Id = id };
            var value = new PropertyValue { Type = 31, Text = Marshal.StringToCoTaskMemUni(text) };
            try { store.SetValue(ref key, ref value); }
            finally { Marshal.FreeCoTaskMem(value.Text); }
        }
    }
}
