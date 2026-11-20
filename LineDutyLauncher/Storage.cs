using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LineDutyLauncher;

internal sealed class UserError(string message) : Exception(message);

internal static class Storage
{
    internal static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    internal static string Json(object value) => JsonSerializer.Serialize(value, JsonOptions);
    internal static JsonObject ReadObject(string path) => JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8))?.AsObject() ?? throw new UserError("資料格式無法讀取。");
    internal static void AtomicWrite(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { f.Write(bytes); f.Flush(true); }
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    internal static void WriteObject(string path, object value) => AtomicWrite(path, Encoding.UTF8.GetBytes(Json(value)));
    internal static string UnprotectFile(string path)
    {
        var clear = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        try { return Encoding.UTF8.GetString(clear); } finally { CryptographicOperations.ZeroMemory(clear); }
    }
    internal static void ProtectFile(string path, string json)
    {
        var clear = Encoding.UTF8.GetBytes(json);
        try { AtomicWrite(path, ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }
    internal static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    internal static void RejectReparse(string path)
    {
        var directory = Directory.Exists(path) ? new DirectoryInfo(path) : new FileInfo(path).Directory;
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new UserError("資料路徑不可使用連結或重新解析點。");
        while (directory is not null) { if (directory.Exists && directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UserError("資料路徑不可使用連結或重新解析點。"); directory = directory.Parent; }
    }
}

internal sealed class Control
{
    public int Version { get; set; } = 1;
    public string DatasetId { get; set; } = Guid.NewGuid().ToString("N");
    public string State { get; set; } = "stopped";
    public string? TransferId { get; set; }
    public DateTimeOffset? ResumeAfterUtc { get; set; }
    public static Control Load(string root)
    {
        string p = Path.Combine(root, "control.json");
        var value = File.Exists(p) ? JsonSerializer.Deserialize<Control>(File.ReadAllText(p)) ?? throw new UserError("啟動狀態無法讀取。") : new Control();
        if (value.Version != 1 || !Guid.TryParseExact(value.DatasetId, "N", out _) || value.State is not ("ready" or "stopped" or "exporting" or "transferred")) throw new UserError("啟動狀態版本或格式不支援，請勿手動刪除狀態檔。");
        return value;
    }
    public void Save(string root) => Storage.WriteObject(Path.Combine(root, "control.json"), this);
}

internal sealed class AppHost
{
    public string AppRoot { get; }
    public string DataRoot { get; }
    public string ConfigPath => Path.Combine(DataRoot, "appsettings.json");
    public string Core => Path.Combine(AppRoot, "app");
    public string PowerShellPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    public AppHost(string appRoot, string dataRoot) { AppRoot = Path.GetFullPath(appRoot); DataRoot = Path.GetFullPath(dataRoot); }
    internal System.Diagnostics.ProcessStartInfo PsInfo(string script, string config)
    {
        var p = new System.Diagnostics.ProcessStartInfo(PowerShellPath) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Core, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", Path.Combine(Core, script), "-ConfigPath", config }) p.ArgumentList.Add(a);
        return p;
    }
    public async Task<JsonObject> Bridge(string action, string? root = null)
    {
        var info = PsInfo("Portable.Bridge.ps1", Path.Combine(root ?? DataRoot, "appsettings.json"));
        info.ArgumentList.Add("-Action"); info.ArgumentList.Add(action);
        using var p = System.Diagnostics.Process.Start(info) ?? throw new UserError("無法啟動 Windows PowerShell。");
        var stdout = p.StandardOutput.ReadToEndAsync(); var stderr = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        string result = await stdout; _ = await stderr;
        JsonObject value;
        try { value = JsonNode.Parse(result)?.AsObject() ?? throw new Exception(); }
        catch { throw new UserError("必要元件無法執行，請檢查 Windows PowerShell 或公司執行政策。"); }
        if (p.ExitCode != 0) throw new UserError(value["Error"]?.ToString() == "quiesce_timeout" ? "程式尚未安全停止。舊版監測器可能不支援暫停，或班表辨識仍在執行；請先完成工作、以新版重新啟動後再重試。" : "操作未完成，請核對設定、執行權限或本機資料。");
        return value;
    }
    public void OpenView(string name)
    {
        if (!File.Exists(ConfigPath)) throw new UserError("請先完成設定或匯入資料。");
        if (name == "Show-TeamManagement.ps1" && Control.Load(DataRoot).State is "exporting" or "transferred") throw new UserError("資料正在搬遷或已移轉，暫時無法修改。");
        var info = PsInfo(name, ConfigPath); info.RedirectStandardOutput = false; info.RedirectStandardError = false;
        info.StandardOutputEncoding = null; info.StandardErrorEncoding = null;
        _ = System.Diagnostics.Process.Start(info);
    }
    public void Rebind(JsonObject config)
    {
        config["NotificationDatabase"]!["DatabasePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Notifications", "wpndatabase.db");
        config["NotificationDatabase"]!["SqlitePath"] = Path.Combine(AppRoot, "tools", "sqlite3.exe");
    }
    public async Task Start()
    {
        if (!File.Exists(ConfigPath)) throw new UserError("請先完成設定或匯入資料。");
        var c = Control.Load(DataRoot);
        if (c.State is "exporting" or "transferred") throw new UserError("此資料已進入搬遷模式；若要恢復舊機，請使用取消搬遷功能。");
        // Drain workers from the previous application location before rebinding after an update.
        c.State = "stopped"; c.Save(DataRoot); await Bridge("quiesce");
        var config = Storage.ReadObject(ConfigPath); Rebind(config); Storage.WriteObject(ConfigPath, config);
        c.State = "ready"; c.Save(DataRoot);
        await Bridge("initialize"); await Bridge("start");
    }
    public async Task Stop()
    {
        if (!File.Exists(ConfigPath)) return;
        var c = Control.Load(DataRoot); if (c.State is not ("exporting" or "transferred")) { c.State = "stopped"; c.Save(DataRoot); }
        await Bridge("quiesce");
    }
    internal static string[] SecretNames(JsonObject config) => new[] { config["Ai"]?["ApiKeyEnvironmentVariable"]?.ToString() ?? "OPENAI_API_KEY", config["Pushover"]?["AppTokenEnvironmentVariable"]?.ToString() ?? "PUSHOVER_APP_TOKEN", config["Pushover"]?["UserKeyEnvironmentVariable"]?.ToString() ?? "PUSHOVER_USER_KEY" };
    internal static Dictionary<string, string> ReadSecrets(string root, JsonObject config)
    {
        string path = Path.Combine(root, "secrets.dat");
        var values = File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<string, string>>(Storage.UnprotectFile(path)) ?? [] : new Dictionary<string, string>();
        var names = SecretNames(config).ToList();
        string model = Path.Combine(root, "state", "team", "model.dat");
        if (File.Exists(model))
        {
            var data = JsonNode.Parse(Storage.UnprotectFile(model));
            foreach (var person in data?["People"]?.AsArray() ?? []) { string? name = person?["KeyEnvironment"]?.ToString(); if (!string.IsNullOrEmpty(name)) names.Add(name); }
        }
        foreach (string name in names.Distinct()) if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value)) values[name] = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User) ?? Environment.GetEnvironmentVariable(name) ?? "";
        return values;
    }
}
