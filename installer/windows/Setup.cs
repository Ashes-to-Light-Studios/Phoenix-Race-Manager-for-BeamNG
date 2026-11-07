// Phoenix Race Manager Setup: installs PRM into a BeamMP server folder.
//
// ONE FILE. The release zip is embedded in this exe, so a server owner
// downloads it, opens it and is done. It finds the server, copies what it
// replaces into _attic\, writes Resources\Client\RaceManager.zip and the
// plugin's .lua files, and never touches Resources\Server\RaceManager\Data.
// The rules are the in-game updater's (server/RaceManager/update.lua).
//
// C# 5, built by build.ps1 with the compiler in .NET Framework 4.x, which
// every Windows 10 and 11 has: nothing to install to build it or to run it.
//
//   PRM-Setup.exe                              the window
//   PRM-Setup.exe /server "C:\BeamMP"          the window, that folder chosen
//   PRM-Setup.exe /server "C:\BeamMP" /quiet   no window; exit code 0 = done

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PhoenixRaceManager
{
    static class Program
    {
        [DllImport("kernel32.dll")]
        static extern bool AttachConsole(int pid);

        [STAThread]
        static int Main(string[] args)
        {
            string server = null;
            bool quiet = false;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if ((a == "/server" || a == "--server") && i + 1 < args.Length) server = args[++i];
                else if (a == "/quiet" || a == "--quiet") quiet = true;
            }

            Release release = null;
            string error = null;
            try { release = Release.Load(); }
            catch (Exception e) { error = e.Message; }

            if (quiet)
            {
                // A window app has no console of its own: borrow the caller's.
                AttachConsole(-1);
                if (release == null) { Console.Error.WriteLine("PRM Setup: " + error); return 1; }
                return Quiet(release, server);
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (release == null)
            {
                MessageBox.Show(error, "Phoenix Race Manager Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            Application.Run(new SetupForm(release, server));
            return 0;
        }

        static int Quiet(Release release, string server)
        {
            if (server == null)
            {
                List<string> found = Server.Find();
                if (found.Count != 1)
                {
                    Console.Error.WriteLine(found.Count == 0
                        ? "PRM Setup: no BeamMP server found. Pass /server \"<folder>\"."
                        : "PRM Setup: several BeamMP servers found. Pass /server \"<folder>\":\n  "
                          + string.Join("\n  ", found));
                    return 2;
                }
                server = found[0];
            }
            var job = new Installer(release, server);
            bool ok = job.Run();
            Console.WriteLine(job.Report());
            return ok ? 0 : 1;
        }
    }

    // The release this exe carries: the client zip and the plugin's files.
    sealed class Release
    {
        public string Version;
        public byte[] ClientZip;
        public readonly SortedDictionary<string, byte[]> Plugin =
            new SortedDictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);

        public static Release Load()
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("RaceManager.zip"))
            {
                if (s == null)
                    throw new InvalidOperationException("This installer is damaged: there is no release inside it. Download it again.");
                using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    var r = new Release();
                    foreach (ZipArchiveEntry e in zip.Entries)
                    {
                        string name = e.FullName.Replace('\\', '/');
                        if (name.EndsWith("/")) continue;
                        if (name == "Client/RaceManager.zip") r.ClientZip = Bytes(e);
                        else if (Regex.IsMatch(name, @"^Server/RaceManager/[A-Za-z0-9_\-]+\.lua$"))
                            r.Plugin[name.Substring("Server/RaceManager/".Length)] = Bytes(e);
                        else if (name.IndexOf('/') >= 0)
                            throw new InvalidOperationException("The release inside this installer holds " + name
                                + ", which it does not know where to put.");
                    }
                    if (r.ClientZip == null || !r.Plugin.ContainsKey("main.lua"))
                        throw new InvalidOperationException("This installer is damaged: the release inside it is incomplete. Download it again.");
                    r.Version = Server.BuildOf(Encoding.UTF8.GetString(r.Plugin["main.lua"])) ?? "?";
                    return r;
                }
            }
        }

        static byte[] Bytes(ZipArchiveEntry e)
        {
            using (Stream s = e.Open())
            using (var m = new MemoryStream())
            {
                s.CopyTo(m);
                return m.ToArray();
            }
        }
    }

    static class Server
    {
        const string Key = @"Software\Phoenix Race Manager";

        // A BeamMP server folder: its config, or its exe before a first run has
        // written the config.
        public static bool IsServer(string dir)
        {
            try
            {
                return !string.IsNullOrEmpty(dir)
                    && (File.Exists(Path.Combine(dir, "ServerConfig.toml"))
                        || File.Exists(Path.Combine(dir, "BeamMP-Server.exe")));
            }
            catch { return false; }
        }

        static string Config(string server)
        {
            try { return File.ReadAllText(Path.Combine(server, "ServerConfig.toml")); }
            catch { return ""; }
        }

        // ResourceFolder from ServerConfig.toml: a server may have renamed it.
        public static string ResourcesDir(string server)
        {
            Match m = Regex.Match(Config(server), @"^[ \t]*ResourceFolder[ \t]*=[ \t]*""([^""\r\n]+)""",
                RegexOptions.Multiline);
            string res = m.Success ? m.Groups[1].Value : "Resources";
            return Path.GetFullPath(Path.IsPathRooted(res) ? res : Path.Combine(server, res));
        }

        public static string MapOf(string server)
        {
            Match m = Regex.Match(Config(server), @"^[ \t]*Map[ \t]*=[ \t]*""[^""\r\n]*?levels/([^/""\r\n]+)",
                RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value : null;
        }

        public static string BuildOf(string mainLua)
        {
            Match m = Regex.Match(mainLua ?? "", @"\nlocal RM_BUILD = '([^']+)'");
            return m.Success ? m.Groups[1].Value : null;
        }

        // The PRM a server has now, or null.
        public static string Installed(string server)
        {
            try
            {
                string main = Path.Combine(ResourcesDir(server), @"Server\RaceManager\main.lua");
                return File.Exists(main) ? BuildOf(File.ReadAllText(main)) : null;
            }
            catch { return null; }
        }

        public static bool Same(string a, string b)
        {
            try
            {
                return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        // Limited-query access, not Process.MainModule: that one is refused for
        // a server running as administrator, and the check would see nothing.
        static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
            }
            finally { CloseHandle(h); }
        }

        public static List<string> Running()
        {
            var dirs = new List<string>();
            foreach (Process p in Process.GetProcessesByName("BeamMP-Server"))
            {
                string path = ImagePath(p.Id);
                if (path != null) dirs.Add(Path.GetDirectoryName(path));
                p.Dispose();
            }
            return dirs;
        }

        public static bool IsRunning(string server)
        {
            return Running().Any(d => Same(d, server));
        }

        public static string Remembered()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Key))
                    return k == null ? null : k.GetValue("ServerFolder") as string;
            }
            catch { return null; }
        }

        public static void Remember(string server)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(Key))
                    k.SetValue("ServerFolder", server);
            }
            catch { }
        }

        static readonly string[] Skip = { "Windows", "$Recycle.Bin", "System Volume Information",
            "ProgramData", "AppData", "node_modules" };

        // Every server folder worth offering: the last one used, any running,
        // the folder this exe is in, then near the top of each drive and the
        // user's own folders. Capped in time: walking a whole disk takes minutes.
        public static List<string> Find()
        {
            var found = new List<string>();
            Action<string> add = delegate (string dir)
            {
                if (!IsServer(dir)) return;
                string full;
                try { full = Path.GetFullPath(dir).TrimEnd('\\'); }
                catch { return; }
                if (!found.Any(f => Same(f, full))) found.Add(full);
            };
            add(Remembered());
            foreach (string d in Running()) add(d);
            add(AppDomain.CurrentDomain.BaseDirectory);
            DateTime stop = DateTime.UtcNow.AddSeconds(4);
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                bool ok;
                try { ok = drive.DriveType == DriveType.Fixed && drive.IsReady; }
                catch { ok = false; }
                if (ok) Scan(drive.RootDirectory.FullName, 3, add, stop);
            }
            foreach (Environment.SpecialFolder f in new[] { Environment.SpecialFolder.UserProfile,
                Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.MyDocuments })
                Scan(Environment.GetFolderPath(f), 2, add, stop);
            return found;
        }

        static void Scan(string dir, int depth, Action<string> add, DateTime stop)
        {
            if (string.IsNullOrEmpty(dir) || DateTime.UtcNow > stop) return;
            add(dir);
            if (depth == 0) return;
            string[] subs;
            try { subs = Directory.GetDirectories(dir); }
            catch { return; }
            foreach (string sub in subs)
            {
                string name = Path.GetFileName(sub);
                if (name.StartsWith(".") || Skip.Any(s => string.Equals(s, name, StringComparison.OrdinalIgnoreCase)))
                    continue;
                Scan(sub, depth - 1, add, stop);
            }
        }

        public static int Compare(string a, string b)
        {
            int[] x = Parts(a), y = Parts(b);
            if (x == null || y == null) return 0;
            for (int i = 0; i < 3; i++) if (x[i] != y[i]) return x[i].CompareTo(y[i]);
            return 0;
        }

        static int[] Parts(string v)
        {
            Match m = Regex.Match(v ?? "", @"^(\d+)\.(\d+)\.(\d+)$");
            if (!m.Success) return null;
            return new[] { int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value) };
        }
    }

    // One install: what is on disk is backed up, then the release is written.
    sealed class Installer
    {
        sealed class Step { public string Path; public byte[] New; public byte[] Old; public string Backup; }

        readonly Release release;
        public readonly string ServerDir, ResourcesDir, ClientDir, PluginDir;
        public string Previous;   // the PRM installed before, or null
        public string Attic;
        public string Error;
        public bool Denied;       // Windows refused a write: run as administrator
        bool done;
        readonly List<string> written = new List<string>();
        readonly List<string> moved = new List<string>();
        readonly List<string> notes = new List<string>();

        public Installer(Release release, string server)
        {
            this.release = release;
            ServerDir = Path.GetFullPath(server).TrimEnd('\\');
            ResourcesDir = Server.ResourcesDir(ServerDir);
            ClientDir = Path.Combine(ResourcesDir, "Client");
            PluginDir = Path.Combine(ResourcesDir, @"Server\RaceManager");
        }

        public bool Run()
        {
            try { return done = RunOrThrow(); }
            catch (UnauthorizedAccessException e)
            {
                Denied = true;
                Error = "Windows would not let the installer write to the server folder (" + e.Message + ")";
                return false;
            }
            catch (Exception e)
            {
                Error = e.Message;
                return false;
            }
        }

        bool RunOrThrow()
        {
            if (!Server.IsServer(ServerDir))
            {
                Error = ServerDir + " is not a BeamMP server folder: it has neither BeamMP-Server.exe nor ServerConfig.toml.";
                return false;
            }
            // BeamMP reloads a changed plugin on the spot, which ends any session
            // in progress, and keeps offering the old client until it restarts.
            if (Server.IsRunning(ServerDir))
            {
                Error = "The BeamMP server in this folder is running. Stop it, then install.";
                return false;
            }
            Previous = Server.Installed(ServerDir);
            Attic = Path.Combine(ServerDir, "_attic", "install-" + (Previous ?? "none") + "-to-" + release.Version
                + "_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss"));

            var steps = new List<Step>();
            steps.Add(new Step { Path = Path.Combine(ClientDir, "RaceManager.zip"), New = release.ClientZip,
                Backup = Path.Combine(Attic, @"Client\RaceManager.zip") });
            foreach (KeyValuePair<string, byte[]> kv in release.Plugin)
                steps.Add(new Step { Path = Path.Combine(PluginDir, kv.Key), New = kv.Value,
                    Backup = Path.Combine(Attic, @"Server\RaceManager\" + kv.Key) });
            // A plugin file this release no longer has: BeamMP runs every .lua in
            // the folder, so it would keep running beside the new ones.
            if (Directory.Exists(PluginDir))
                foreach (string f in Directory.GetFiles(PluginDir))
                {
                    string name = Path.GetFileName(f);
                    if (!name.EndsWith(".lua", StringComparison.OrdinalIgnoreCase) || release.Plugin.ContainsKey(name)) continue;
                    steps.Add(new Step { Path = f, Backup = Path.Combine(Attic, @"Server\RaceManager\" + name) });
                    moved.Add(Rel(f) + " (not part of PRM " + release.Version + ")");
                }

            foreach (Step s in steps)
            {
                if (!File.Exists(s.Path)) continue;
                s.Old = File.ReadAllBytes(s.Path);
                Directory.CreateDirectory(Path.GetDirectoryName(s.Backup));
                File.WriteAllBytes(s.Backup, s.Old);
            }

            var applied = new List<Step>();
            try
            {
                Directory.CreateDirectory(ClientDir);
                Directory.CreateDirectory(PluginDir);
                foreach (Step s in steps)
                {
                    applied.Add(s);
                    if (s.New == null) { File.Delete(s.Path); continue; }
                    File.WriteAllBytes(s.Path, s.New);
                    // Read back: a full disk writes short without saying so.
                    if (!File.ReadAllBytes(s.Path).SequenceEqual(s.New))
                        throw new IOException(s.Path + " did not write correctly (is the disk full?)");
                    written.Add(Rel(s.Path));
                }
            }
            catch (Exception e)
            {
                string lost = Restore(applied);
                Error = "Could not install: " + e.Message + ". "
                    + (lost == null ? "Everything was put back as it was."
                       : "These could not be put back, copy them from " + Attic + ": " + lost);
                if (e is UnauthorizedAccessException) Denied = true;
                written.Clear();
                moved.Clear();
                return false;
            }

            MoveOutOthers();
            Server.Remember(ServerDir);
            done = true;
            try
            {
                Directory.CreateDirectory(Attic);
                File.WriteAllText(Path.Combine(Attic, "install.log"), Report());
            }
            catch { }
            return true;
        }

        static string Restore(List<Step> applied)
        {
            var lost = new List<string>();
            for (int i = applied.Count - 1; i >= 0; i--)
            {
                Step s = applied[i];
                try
                {
                    if (s.Old != null) File.WriteAllBytes(s.Path, s.Old);
                    else if (File.Exists(s.Path)) File.Delete(s.Path);
                }
                catch { lost.Add(s.Path); }
            }
            return lost.Count == 0 ? null : string.Join(", ", lost);
        }

        // Older copies of PRM that would run beside this one: a second client
        // zip (BeamMP sends every zip in Client to every player) and another
        // plugin folder (BeamMP runs every folder in Server). Recognised by what
        // is inside them, never by name alone, and moved, never deleted.
        void MoveOutOthers()
        {
            foreach (string zip in Directory.GetFiles(ClientDir))
            {
                string name = Path.GetFileName(zip);
                if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)
                    || name.Equals("RaceManager.zip", StringComparison.OrdinalIgnoreCase) || !HoldsClient(zip)) continue;
                Move(zip, Path.Combine(Attic, @"Client\" + name), "a second copy of the PRM client");
            }
            string serverRoot = Path.Combine(ResourcesDir, "Server");
            foreach (string dir in Directory.GetDirectories(serverRoot))
            {
                if (Server.Same(dir, PluginDir)) continue;
                string main = Path.Combine(dir, "main.lua");
                string text;
                try { text = File.Exists(main) ? File.ReadAllText(main) : ""; }
                catch { text = ""; }
                if (text.Contains("RM_BUILD") && text.Contains("[RaceManager]"))
                    Move(dir, Path.Combine(Attic, @"Server\" + Path.GetFileName(dir)), "another Race Manager plugin");
            }
        }

        static bool HoldsClient(string zip)
        {
            try
            {
                using (ZipArchive z = new ZipArchive(File.OpenRead(zip), ZipArchiveMode.Read))
                    return z.Entries.Any(e => string.Equals(e.FullName.Replace('\\', '/'),
                        "lua/ge/extensions/raceManager.lua", StringComparison.OrdinalIgnoreCase));
            }
            catch { return false; }
        }

        void Move(string from, string to, string why)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
                moved.Add(Rel(from) + " (" + why + ")");
            }
            catch (Exception e)
            {
                notes.Add("Could not move " + Rel(from) + " (" + why + "): " + e.Message + ". Move it out yourself.");
            }
        }

        string Rel(string path)
        {
            string root = ServerDir + "\\";
            return path.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? path.Substring(root.Length) : path;
        }

        public string Report()
        {
            var b = new StringBuilder();
            if (!done)
            {
                b.AppendLine("Phoenix Race Manager " + release.Version + " was NOT installed.");
                b.AppendLine();
                b.AppendLine(Error);
                return b.ToString();
            }
            string was = Previous == null ? "" : Previous == release.Version ? " (installed again)" : " (it was " + Previous + ")";
            b.AppendLine("Phoenix Race Manager " + release.Version + " is installed in " + ServerDir + was + ".");
            b.AppendLine();
            b.AppendLine("Written:");
            foreach (string w in written) b.AppendLine("  " + w);
            if (moved.Count > 0)
            {
                b.AppendLine("Moved out:");
                foreach (string m in moved) b.AppendLine("  " + m);
            }
            foreach (string n in notes) b.AppendLine(n);
            b.AppendLine("Anything replaced is in " + Rel(Attic) + ".");
            b.AppendLine("Tracks, results and settings in " + Rel(Path.Combine(PluginDir, "Data")) + " were not touched.");
            b.AppendLine();
            b.AppendLine("Next:");
            b.AppendLine("  1. Start the server, or restart it if it is running.");
            b.AppendLine("  2. Players get PRM as they join. Each driver adds Phoenix Race Manager (PRM)");
            b.AppendLine("     once from HUD Apps (search PRM).");
            if (Previous == null)
            {
                b.AppendLine("  3. Log in on the app's admin bar with the password from the README, then set");
                b.AppendLine("     your own on the Admin tab.");
            }
            b.AppendLine("Later releases install from the app's Admin tab: Update and restart.");
            return b.ToString();
        }
    }

    sealed class SetupForm : Form
    {
        static readonly Color Ember = Color.FromArgb(255, 122, 26);
        static readonly Color Good = Color.FromArgb(24, 128, 56);
        static readonly Color Warn = Color.FromArgb(176, 96, 0);
        static readonly Color Bad = Color.FromArgb(200, 40, 40);

        readonly Release release;
        readonly ComboBox folder = new ComboBox();
        readonly Button browse = new Button();
        readonly Button install = new Button();
        readonly Button close = new Button();
        readonly Label status = new Label();
        readonly TextBox details = new TextBox();
        bool searching = true;
        bool finished;

        public SetupForm(Release release, string preset)
        {
            this.release = release;
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = SystemFonts.MessageBoxFont;
            Text = "Phoenix Race Manager " + release.Version + " Setup";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(640, 440);
            Icon icon = LoadIcon(32);
            if (icon != null) Icon = icon;

            var header = new Panel { Dock = DockStyle.Top, Height = 84, BackColor = Color.FromArgb(28, 22, 20) };
            Image logo = LoadLogo(64);
            if (logo != null)
                header.Controls.Add(new PictureBox { Image = logo, SizeMode = PictureBoxSizeMode.Zoom,
                    Bounds = new Rectangle(14, 10, 64, 64) });
            header.Controls.Add(new Label { Text = "Phoenix Race Manager " + release.Version, ForeColor = Ember,
                Font = new Font(Font.FontFamily, 15F, FontStyle.Bold), AutoSize = true, Location = new Point(88, 14) });
            header.Controls.Add(new Label { Text = "Installs PRM into your BeamMP server. Players get it when they join.",
                ForeColor = Color.Gainsboro, AutoSize = true, Location = new Point(90, 48) });

            var body = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(14, 12, 14, 12),
                ColumnCount = 2, RowCount = 5 };
            body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            body.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            body.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            body.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var label = new Label { Text = "BeamMP server folder (the one with BeamMP-Server.exe in it):", AutoSize = true,
                Margin = new Padding(0, 0, 0, 4) };
            body.Controls.Add(label, 0, 0);
            body.SetColumnSpan(label, 2);

            folder.Dock = DockStyle.Fill;
            folder.DropDownStyle = ComboBoxStyle.DropDown;
            folder.Margin = new Padding(0, 1, 6, 0);
            folder.TextChanged += delegate { Check(); };
            body.Controls.Add(folder, 0, 1);
            browse.Text = "Browse...";
            browse.AutoSize = true;
            browse.Margin = new Padding(0);
            browse.Click += OnBrowse;
            body.Controls.Add(browse, 1, 1);

            status.AutoSize = true;
            status.MaximumSize = new Size(600, 0);
            status.Margin = new Padding(0, 8, 0, 8);
            body.Controls.Add(status, 0, 2);
            body.SetColumnSpan(status, 2);

            details.Multiline = true;
            details.ReadOnly = true;
            details.ScrollBars = ScrollBars.Vertical;
            details.Dock = DockStyle.Fill;
            details.BackColor = SystemColors.Window;
            details.Font = new Font(FontFamily.GenericMonospace, 9F);
            details.Text = string.Join(Environment.NewLine, new[] {
                "What this does:",
                "",
                "  1. Copies Resources\\Client\\RaceManager.zip (the part BeamMP sends to",
                "     players) and the plugin in Resources\\Server\\RaceManager into the server.",
                "  2. Keeps anything it replaces in the server's _attic folder first.",
                "  3. Leaves Resources\\Server\\RaceManager\\Data alone: your tracks, results,",
                "     cup and settings carry over.",
                "",
                "Stop the server before installing, then start it again afterwards.",
            });
            body.Controls.Add(details, 0, 3);
            body.SetColumnSpan(details, 2);

            var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill,
                AutoSize = true, Margin = new Padding(0, 10, 0, 0) };
            close.Text = "Close";
            close.Size = new Size(96, 30);
            close.Click += delegate { Close(); };
            install.Text = "Install";
            install.Size = new Size(110, 30);
            install.Enabled = false;
            install.Click += OnInstall;
            buttons.Controls.Add(close);
            buttons.Controls.Add(install);
            body.Controls.Add(buttons, 0, 4);
            body.SetColumnSpan(buttons, 2);

            Controls.Add(body);
            Controls.Add(header);
            AcceptButton = install;
            CancelButton = close;
            ResumeLayout(true);

            if (!string.IsNullOrEmpty(preset)) folder.Text = preset;
            Say("Looking for BeamMP servers on this PC...", SystemColors.GrayText);
            // Once the window exists: BeginInvoke before then throws, and the
            // result of a quick search would be lost.
            Shown += delegate
            {
                ThreadPool.QueueUserWorkItem(delegate
                {
                    List<string> found = Server.Find();
                    try { BeginInvoke((Action)(() => Found(found))); }
                    catch (Exception) { }   // closed before the search ended
                });
            };
        }

        static byte[] IconFile()
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("prm.ico"))
            {
                if (s == null) return null;
                using (var m = new MemoryStream()) { s.CopyTo(m); return m.ToArray(); }
            }
        }

        static Icon LoadIcon(int size)
        {
            try
            {
                byte[] ico = IconFile();
                return ico == null ? null : new Icon(new MemoryStream(ico), new Size(size, size));
            }
            catch { return null; }
        }

        // The .ico holds PNG images, which Icon.ToBitmap turns into noise, so the
        // header's picture is taken out of the .ico by hand. The stream stays
        // open: GDI+ reads from it for as long as the image lives.
        static Image LoadLogo(int size)
        {
            try
            {
                byte[] ico = IconFile();
                if (ico == null) return null;
                int count = BitConverter.ToUInt16(ico, 4);
                for (int i = 0; i < count; i++)
                {
                    int e = 6 + 16 * i;
                    if ((ico[e] == 0 ? 256 : ico[e]) != size) continue;
                    return Image.FromStream(new MemoryStream(ico, BitConverter.ToInt32(ico, e + 12),
                        BitConverter.ToInt32(ico, e + 8)));
                }
            }
            catch { }
            return null;
        }

        void Found(List<string> found)
        {
            searching = false;
            // Installed before the search ended: the result must not overwrite
            // "Installed" with the state of the folder before it.
            if (finished) return;
            folder.Items.Clear();
            foreach (string f in found) folder.Items.Add(f);
            if (folder.Text.Trim().Length == 0 && found.Count > 0) folder.SelectedIndex = 0;
            Check();
            if (found.Count == 0 && folder.Text.Trim().Length == 0)
                Say("No BeamMP server found on this PC. Press Browse and choose its folder.", Warn);
        }

        void Say(string text, Color color)
        {
            status.Text = text;
            status.ForeColor = color;
        }

        void Check()
        {
            string dir = folder.Text.Trim();
            install.Enabled = false;
            if (dir.Length == 0)
            {
                if (!searching) Say("Choose the folder that holds BeamMP-Server.exe.", SystemColors.GrayText);
                return;
            }
            if (!Directory.Exists(dir)) { Say("That folder does not exist.", Bad); return; }
            if (!Server.IsServer(dir))
            {
                Say("No BeamMP server here: this folder has neither BeamMP-Server.exe nor ServerConfig.toml.", Bad);
                return;
            }
            string have = Server.Installed(dir), map = Server.MapOf(dir);
            string what;
            Color color = Good;
            if (have == null) what = "PRM is not installed here yet.";
            else if (have == release.Version) what = "PRM " + have + " is already installed: this installs it again.";
            else if (Server.Compare(have, release.Version) > 0)
            {
                what = "PRM " + have + " is installed, which is NEWER than this installer's " + release.Version + ".";
                color = Warn;
            }
            else what = "PRM " + have + " is installed: this updates it to " + release.Version + ".";
            if (Server.IsRunning(dir))
            {
                what = "This server is running: stop it before installing. " + what;
                color = Warn;
            }
            Say("BeamMP server found" + (map != null ? " (map " + map + ")" : "") + ". " + what, color);
            install.Enabled = true;
        }

        void OnBrowse(object sender, EventArgs e)
        {
            using (var pick = new FolderBrowserDialog())
            {
                pick.Description = "Choose the BeamMP server folder: the one with BeamMP-Server.exe in it.";
                pick.ShowNewFolderButton = false;
                if (Directory.Exists(folder.Text.Trim())) pick.SelectedPath = folder.Text.Trim();
                if (pick.ShowDialog(this) == DialogResult.OK) folder.Text = pick.SelectedPath;
            }
        }

        void OnInstall(object sender, EventArgs e)
        {
            string dir = folder.Text.Trim();
            if (Server.IsRunning(dir))
            {
                MessageBox.Show(this, "The BeamMP server in this folder is running.\n\nStop it, then press Install: "
                    + "changing the plugin while it runs ends any session in progress.",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            install.Enabled = false;
            UseWaitCursor = true;
            var job = new Installer(release, dir);
            bool ok = job.Run();
            UseWaitCursor = false;
            details.Text = job.Report().Replace("\r\n", "\n").Replace("\n", Environment.NewLine);
            if (ok)
            {
                finished = true;
                Say("Installed. Start the server and you are done.", Good);
                install.Visible = false;
                close.Text = "Done";
                folder.Enabled = browse.Enabled = false;
                // Focus would land on the report and select all of it.
                close.Focus();
                details.Select(0, 0);
                return;
            }
            Say(job.Denied ? "Windows would not let this installer write there." : "Not installed: see below.", Bad);
            install.Enabled = true;
            if (job.Denied && MessageBox.Show(this, "Windows would not let this installer write to\n" + job.ServerDir
                    + "\n\nRun it again as administrator?", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question)
                == DialogResult.Yes)
                Elevate(job.ServerDir);
        }

        void Elevate(string dir)
        {
            // A trailing backslash would escape the closing quote.
            if (dir.EndsWith("\\")) dir += "\\";
            try
            {
                Process.Start(new ProcessStartInfo(Application.ExecutablePath, "/server \"" + dir + "\"")
                    { Verb = "runas", UseShellExecute = true });
                Close();
            }
            catch (System.ComponentModel.Win32Exception) { }   // the UAC prompt was declined
        }
    }
}
