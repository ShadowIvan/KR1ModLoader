// KR1ModLoader Setup -- GUI installer for the Kingdom Rush mod loader.
//
// A single exe with no dependencies (.NET Framework 4.x, part of Windows). Does
// the same as install.bat / tools/modloader.py install: finds Kingdom Rush.exe,
// rewrites the zip part of the exe (main.lua -> modloader/game_main.lua plus the
// loader's three Lua files, embedded in this exe as plain resources) and creates
// the Mods folder. Remove reverses that inside the exe. The game's PE part is
// not changed and no backup copy is made.
//
// Build: powershell -File tools/build_setup.ps1  (csc from .NET Framework).
// With arguments it works as a console tool:
//   KR1ModLoader-Setup.exe install ["<path>\Kingdom Rush.exe"]
//   KR1ModLoader-Setup.exe uninstall ["<path>\Kingdom Rush.exe"]
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

class Fused
{
    public const string ExeName = "Kingdom Rush.exe";
    public const string LoaderMark = "modloader/loader.lua";
    public const string GameMain = "modloader/game_main.lua";

    public class Entry
    {
        public string Name;
        public ushort Method, Time, Date;
        public uint Crc, CSize, USize, ExtAttr;
        public int DataOff;     // offset of the compressed data in the source file
        public byte[] Raw;      // or ready bytes (new files)
    }

    public byte[] Data;
    public int Start;
    public List<Entry> Entries = new List<Entry>();

    public static Fused Read(string path)
    {
        var f = new Fused { Data = File.ReadAllBytes(path) };
        var d = f.Data;
        int eocd = -1;
        for (int i = d.Length - 22; i >= Math.Max(0, d.Length - 22 - 65535); i--)
            if (d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 0x05 && d[i + 3] == 0x06) { eocd = i; break; }
        if (eocd < 0) throw new Exception("not a fused LOVE executable: no zip archive found");
        int total = BitConverter.ToUInt16(d, eocd + 10);
        long cdSize = BitConverter.ToUInt32(d, eocd + 12);
        long cdOffset = BitConverter.ToUInt32(d, eocd + 16);
        long start = eocd - cdSize - cdOffset;
        if (start < 0 || BitConverter.ToUInt32(d, (int)start) != 0x04034B50) throw new Exception("could not locate the archive start");
        f.Start = (int)start;
        int p = (int)(start + cdOffset);
        for (int n = 0; n < total; n++)
        {
            if (BitConverter.ToUInt32(d, p) != 0x02014B50) throw new Exception("corrupt central directory");
            int nlen = BitConverter.ToUInt16(d, p + 28), elen = BitConverter.ToUInt16(d, p + 30), clen = BitConverter.ToUInt16(d, p + 32);
            int lh = f.Start + (int)BitConverter.ToUInt32(d, p + 42);
            int lnlen = BitConverter.ToUInt16(d, lh + 26), lelen = BitConverter.ToUInt16(d, lh + 28);
            f.Entries.Add(new Entry
            {
                Name = Encoding.UTF8.GetString(d, p + 46, nlen),
                Method = BitConverter.ToUInt16(d, p + 10), Time = BitConverter.ToUInt16(d, p + 12), Date = BitConverter.ToUInt16(d, p + 14),
                Crc = BitConverter.ToUInt32(d, p + 16), CSize = BitConverter.ToUInt32(d, p + 20), USize = BitConverter.ToUInt32(d, p + 24),
                ExtAttr = BitConverter.ToUInt32(d, p + 38), DataOff = lh + 30 + lnlen + lelen,
            });
            p += 46 + nlen + elen + clen;
        }
        return f;
    }

    public bool Has(string name) { foreach (var e in Entries) if (e.Name == name) return true; return false; }

    static readonly uint[] CrcTable = BuildCrc();
    static uint[] BuildCrc()
    {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1; t[i] = c; }
        return t;
    }
    static uint Crc32(byte[] b) { uint c = 0xFFFFFFFF; foreach (var x in b) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8); return c ^ 0xFFFFFFFF; }

    public void Remove(Predicate<string> match) { Entries.RemoveAll(e => match(e.Name)); }

    public void Put(string name, byte[] content)
    {
        var ms = new MemoryStream();
        using (var ds = new DeflateStream(ms, CompressionLevel.Optimal, true)) ds.Write(content, 0, content.Length);
        var e = new Entry { Name = name, Method = 8, Time = 0, Date = 0x21, Crc = Crc32(content), CSize = (uint)ms.Length, USize = (uint)content.Length, Raw = ms.ToArray() };
        for (int i = 0; i < Entries.Count; i++) if (Entries[i].Name == name) { Entries[i] = e; return; }
        Entries.Add(e);
    }

    public void Write(string path)
    {
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (var bw = new BinaryWriter(fs))
        {
            bw.Write(Data, 0, Start);
            var central = new MemoryStream();
            var cw = new BinaryWriter(central);
            const ushort flags = 0x800;
            foreach (var e in Entries)
            {
                var name = Encoding.UTF8.GetBytes(e.Name);
                uint offset = (uint)(fs.Position - Start);
                bw.Write(0x04034B50u); bw.Write((ushort)20); bw.Write(flags); bw.Write(e.Method); bw.Write(e.Time); bw.Write(e.Date);
                bw.Write(e.Crc); bw.Write(e.CSize); bw.Write(e.USize); bw.Write((ushort)name.Length); bw.Write((ushort)0); bw.Write(name);
                if (e.Raw != null) bw.Write(e.Raw); else bw.Write(Data, e.DataOff, (int)e.CSize);
                cw.Write(0x02014B50u); cw.Write((ushort)20); cw.Write((ushort)20); cw.Write(flags); cw.Write(e.Method); cw.Write(e.Time); cw.Write(e.Date);
                cw.Write(e.Crc); cw.Write(e.CSize); cw.Write(e.USize); cw.Write((ushort)name.Length); cw.Write((ushort)0); cw.Write((ushort)0);
                cw.Write((ushort)0); cw.Write((ushort)0); cw.Write(e.ExtAttr); cw.Write(offset); cw.Write(name);
            }
            uint cdOffset = (uint)(fs.Position - Start);
            var cd = central.ToArray();
            bw.Write(cd);
            bw.Write(0x06054B50u); bw.Write((ushort)0); bw.Write((ushort)0); bw.Write((ushort)Entries.Count); bw.Write((ushort)Entries.Count);
            bw.Write((uint)cd.Length); bw.Write(cdOffset); bw.Write((ushort)0);
        }
    }
}

static class Installer
{
    public static Action<string> Log = s => Console.WriteLine(s);

    // The loader's Lua files are embedded as "bootstrap/<path>" resources (see build_setup.ps1).
    static Dictionary<string, byte[]> Bootstrap()
    {
        var result = new Dictionary<string, byte[]>();
        var asm = Assembly.GetExecutingAssembly();
        foreach (var res in asm.GetManifestResourceNames())
        {
            if (!res.StartsWith("bootstrap/")) continue;
            using (var s = asm.GetManifestResourceStream(res))
            using (var ms = new MemoryStream()) { s.CopyTo(ms); result[res.Substring("bootstrap/".Length)] = ms.ToArray(); }
        }
        if (result.Count == 0) throw new Exception("no loader files inside the installer (bootstrap/* resources)");
        return result;
    }

    public static string FindGame()
    {
        var dirs = new List<string> {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Steam\steamapps\common\Kingdom Rush"),
        };
        try
        {
            var steam = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string;
            if (!string.IsNullOrEmpty(steam))
            {
                steam = steam.Replace('/', '\\');
                dirs.Add(Path.Combine(steam, @"steamapps\common\Kingdom Rush"));
                var vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                if (File.Exists(vdf))
                    foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                        dirs.Add(Path.Combine(m.Groups[1].Value.Replace("\\\\", "\\"), @"steamapps\common\Kingdom Rush"));
            }
        }
        catch { }
        foreach (var d in dirs) { var exe = Path.Combine(d, Fused.ExeName); if (File.Exists(exe)) return exe; }
        return null;
    }

    public static void Install(string gameExe)
    {
        var dir = Path.GetDirectoryName(gameExe);
        Log("Game folder: " + dir);
        Log("Reading " + Fused.ExeName + " ...");
        var exe = Fused.Read(gameExe);
        bool forked = exe.Has(Fused.LoaderMark);
        Log("  loader: " + (forked ? "already installed, updating it" : "not installed"));

        if (!forked)
        {
            var main = exe.Entries.Find(e => e.Name == "main.lua");
            if (main == null) throw new Exception("no main.lua in the archive");
            main.Name = Fused.GameMain;
        }
        foreach (var kv in Bootstrap()) exe.Put(kv.Key, kv.Value);
        var tmp = gameExe + ".tmp";
        exe.Write(tmp);
        File.Delete(gameExe);
        File.Move(tmp, gameExe);
        var mods = Path.Combine(dir, "Mods");
        Directory.CreateDirectory(mods);
        Log("Done: " + gameExe);
        Log("Put mods into: " + mods);
        Log("Loader log after launch: " + Path.Combine(dir, "modloader.log"));
    }

    public static void Uninstall(string gameExe)
    {
        Log("Reading " + Fused.ExeName + " ...");
        var exe = Fused.Read(gameExe);
        var main = exe.Entries.Find(e => e.Name == Fused.GameMain);
        if (main == null) throw new Exception("the loader is not installed in this exe");
        exe.Remove(n => n == "main.lua" || n.StartsWith("modloader/"));
        main.Name = "main.lua";
        exe.Entries.Add(main);
        var tmp = gameExe + ".tmp";
        exe.Write(tmp);
        File.Delete(gameExe);
        File.Move(tmp, gameExe);
        Log("Loader removed: " + gameExe + ". The Mods folder is left in place.");
    }
}

class SetupForm : Form
{
    readonly TextBox path = new TextBox { Left = 12, Top = 32, Width = 430 };
    readonly TextBox log = new TextBox { Left = 12, Top = 100, Width = 520, Height = 200, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9) };

    public SetupForm()
    {
        Text = "KR1ModLoader Setup " + Version();
        ClientSize = new Size(544, 312);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(new Label { Left = 12, Top = 12, Width = 400, Text = "Kingdom Rush.exe:" });
        Controls.Add(path);
        var browse = new Button { Left = 448, Top = 30, Width = 84, Text = "Browse..." };
        browse.Click += (s, e) =>
        {
            using (var d = new OpenFileDialog { Filter = "Kingdom Rush.exe|Kingdom Rush.exe|exe|*.exe", FileName = Fused.ExeName })
                if (d.ShowDialog() == DialogResult.OK) path.Text = d.FileName;
        };
        Controls.Add(browse);
        var install = new Button { Left = 340, Top = 62, Width = 96, Text = "Install" };
        var uninstall = new Button { Left = 442, Top = 62, Width = 90, Text = "Remove" };
        install.Click += (s, e) => Run(() => Installer.Install(path.Text));
        uninstall.Click += (s, e) => Run(() => Installer.Uninstall(path.Text));
        Controls.Add(install); Controls.Add(uninstall);
        Controls.Add(log);
        Installer.Log = line => { log.AppendText(line + Environment.NewLine); Application.DoEvents(); };
        path.Text = Installer.FindGame() ?? "";
        if (path.Text == "") Installer.Log("Kingdom Rush.exe was not found automatically -- enter the path.");
        else Installer.Log("Game found: " + path.Text);
        Installer.Log("Install changes only the zip part of the exe; Remove puts it back.");
    }

    static string Version()
    {
        var v = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>();
        return v != null ? v.InformationalVersion : "";
    }

    void Run(Action a)
    {
        if (!File.Exists(path.Text)) { Installer.Log("ERROR: file not found: " + path.Text); return; }
        UseWaitCursor = true;
        try { a(); }
        catch (Exception ex) { Installer.Log("ERROR: " + ex.Message); }
        finally { UseWaitCursor = false; }
    }
}

static class Program
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            AttachConsole(-1);
            Console.OutputEncoding = Encoding.UTF8;
            var exe = args.Length > 1 ? args[1] : Installer.FindGame();
            try
            {
                if (exe == null || !File.Exists(exe)) throw new Exception("Kingdom Rush.exe not found, pass the path as the second argument");
                if (args[0] == "install") Installer.Install(exe);
                else if (args[0] == "uninstall") Installer.Uninstall(exe);
                else throw new Exception("usage: KR1ModLoader-Setup.exe install|uninstall [\"path\\Kingdom Rush.exe\"]");
                return 0;
            }
            catch (Exception ex) { Console.WriteLine("error: " + ex.Message); return 1; }
        }
        Application.EnableVisualStyles();
        Application.Run(new SetupForm());
        return 0;
    }
}
