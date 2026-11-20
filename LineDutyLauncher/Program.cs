using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LineDutyLauncher;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string data = Path.Combine(root, "LineDutyNotifier");
        for (int i = 0; i < args.Length; i++) if (args[i] == "--data-dir" && i + 1 < args.Length) data = Path.GetFullPath(args[++i]);
        var host = new AppHost(AppContext.BaseDirectory, data);
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest.Run(host, Path.GetFullPath(args[1]));
        if (args.Length == 2 && args[0] == "--preview")
        {
            using var form = new MainForm(host, true); form.Show(); Application.DoEvents();
            using var image = new Bitmap(form.Width, form.Height); form.DrawToBitmap(image, form.ClientRectangle); image.Save(args[1]); return 0;
        }
        if (RuntimeInformation.OSArchitecture != Architecture.X64 || Environment.OSVersion.Version.Build < 22000)
        { MessageBox.Show("此版本適用 Windows 11 x64。", "系統不符"); return 1; }
        using var mutex = new Mutex(false, "Local\\LineDutyPortable-" + Storage.Hash(data.ToUpperInvariant())[..20]);
        bool owned;
        try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
        if (!owned) { MessageBox.Show("這份資料的啟動器已開啟，請使用原本視窗。", "LINE 值班通知"); return 0; }
        try { Application.Run(new MainForm(host)); return 0; }
        catch { MessageBox.Show("啟動未完成。請完整解壓縮程式資料夾，並確認目前帳號有資料讀寫權限。", "LINE 值班通知"); return 1; }
        finally { mutex.ReleaseMutex(); }
    }
}
