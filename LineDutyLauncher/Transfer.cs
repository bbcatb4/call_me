using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace LineDutyLauncher;

internal sealed class TransferDocument
{
    public int Version { get; set; } = 1;
    public string TransferId { get; set; } = Guid.NewGuid().ToString("N");
    public string DatasetId { get; set; } = "";
    public DateTimeOffset ResumeAfterUtc { get; set; }
    public JsonObject Config { get; set; } = new();
    public Dictionary<string, string> Secrets { get; set; } = [];
    public Dictionary<string, string> Records { get; set; } = [];
}

internal static class TransferCrypto
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("LDNTF001");
    internal const int Iterations = 600_000;
    internal const int MaxBytes = 256 * 1024 * 1024;
    internal static byte[] Encrypt(TransferDocument data, string password)
    {
        if (password.Length < 12) throw new UserError("移轉密碼至少需要 12 個字元。");
        byte[] clear = JsonSerializer.SerializeToUtf8Bytes(data);
        if (clear.Length > MaxBytes) throw new UserError("資料超過目前移轉檔容量上限 256 MB。");
        byte[] salt = RandomNumberGenerator.GetBytes(32), nonce = RandomNumberGenerator.GetBytes(12);
        byte[] key = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, 32);
        byte[] output = new byte[68 + clear.Length];
        Magic.CopyTo(output, 0); salt.CopyTo(output, 8); nonce.CopyTo(output, 40);
        try { using var aes = new AesGcm(key, 16); aes.Encrypt(nonce, clear, output.AsSpan(68), output.AsSpan(52, 16), output.AsSpan(0, 52)); return output; }
        finally { CryptographicOperations.ZeroMemory(clear); CryptographicOperations.ZeroMemory(key); }
    }
    internal static TransferDocument Decrypt(byte[] input, string password)
    {
        if (input.Length < 69 || input.Length > MaxBytes + 68 || !input.AsSpan(0, 8).SequenceEqual(Magic)) throw new UserError("移轉檔格式或版本不支援。");
        byte[] key = Rfc2898DeriveBytes.Pbkdf2(password, input.AsSpan(8, 32), Iterations, HashAlgorithmName.SHA256, 32);
        byte[] clear = new byte[input.Length - 68];
        try
        {
            using var aes = new AesGcm(key, 16); aes.Decrypt(input.AsSpan(40, 12), input.AsSpan(68), input.AsSpan(52, 16), clear, input.AsSpan(0, 52));
            return JsonSerializer.Deserialize<TransferDocument>(clear) ?? throw new UserError("移轉資料無效。");
        }
        catch (CryptographicException) { throw new UserError("密碼錯誤或移轉檔已損壞；未匯入任何資料。"); }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(clear); }
    }
}

internal sealed class TransferService(AppHost host)
{
    private static readonly HashSet<string> Folders = ["inbox", "processed", "outbox", "usage", "team", "rosters", "dispatch", "schedules", "sources"];
    internal static void Validate(TransferDocument doc)
    {
        if (doc.Version != 1 || !Guid.TryParseExact(doc.TransferId, "N", out _) || !Guid.TryParseExact(doc.DatasetId, "N", out _)) throw new UserError("移轉資料版本或識別碼無效。");
        if (doc.ResumeAfterUtc > DateTimeOffset.UtcNow.AddMinutes(5) || doc.ResumeAfterUtc.Year < 2020) throw new UserError("移轉時間無效，請檢查電腦時間。");
        if (doc.Config["NotificationDatabase"] is not JsonObject || doc.Config["Ai"] is not JsonObject || doc.Config["Pushover"] is not JsonObject || doc.Config["TargetGroupNames"] is not JsonArray) throw new UserError("移轉設定不完整。");
        if (doc.Records.Count > 50_000) throw new UserError("移轉筆數超過目前支援範圍。");
        if (doc.Records.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != doc.Records.Count) throw new UserError("移轉檔包含重複路徑。");
        foreach (var (path, value) in doc.Records)
        {
            string[] parts = path.Split('/');
            if (parts.Length != 2 || !Folders.Contains(parts[0]) || !Regex.IsMatch(parts[1], @"\A[a-zA-Z0-9_-]{1,160}\.dat\z")) throw new UserError("移轉檔包含不允許的路徑。");
            if (JsonNode.Parse(value) is not JsonObject) throw new UserError("移轉紀錄格式無效。");
        }
        foreach (string name in doc.Secrets.Keys) if (!Regex.IsMatch(name, @"\A[A-Za-z_][A-Za-z0-9_]{0,127}\z")) throw new UserError("移轉金鑰名稱無效。");
    }
    internal static TransferDocument Capture(string source, Control control, DateTimeOffset cutoff)
    {
        Storage.RejectReparse(source);
        var config = Storage.ReadObject(Path.Combine(source, "appsettings.json"));
        var doc = new TransferDocument { DatasetId = control.DatasetId, ResumeAfterUtc = cutoff, Config = config, Secrets = AppHost.ReadSecrets(source, config) };
        config["NotificationDatabase"]!["DatabasePath"] = ""; config["NotificationDatabase"]!["SqlitePath"] = "";
        foreach (string folder in Folders)
        {
            string path = Path.Combine(source, "state", folder); if (!Directory.Exists(path)) continue;
            Storage.RejectReparse(path);
            foreach (string file in Directory.EnumerateFiles(path, "*.dat", SearchOption.TopDirectoryOnly))
            {
                Storage.RejectReparse(file);
                doc.Records.Add(folder + "/" + Path.GetFileName(file), Storage.UnprotectFile(file));
            }
        }
        Validate(doc); return doc;
    }
    public async Task Export(string source, string destination, string password)
    {
        source = Path.GetFullPath(source); destination = Path.GetFullPath(destination);
        if (password.Length < 12) throw new UserError("移轉密碼至少需要 12 個字元。");
        if (!File.Exists(Path.Combine(source, "appsettings.json"))) throw new UserError("所選來源資料夾沒有 appsettings.json。");
        if (File.Exists(destination)) throw new UserError("目的檔案已存在，請使用新的檔名。");
        Storage.RejectReparse(source); Storage.RejectReparse(destination);
        var original = Control.Load(source);
        if (!File.Exists(Path.Combine(source, "control.json"))) original.State = "ready";
        if (original.State is "exporting" or "transferred") throw new UserError("來源已在搬遷模式，請先取消搬遷或使用已產生的移轉檔。");
        var oldState = original.State;
        var control = JsonSerializer.Deserialize<Control>(Storage.Json(original))!;
        var cutoff = DateTimeOffset.UtcNow;
        control.State = "exporting"; control.Save(source);
        bool committed = false;
        try
        {
            await host.Bridge("quiesce", source);
            var doc = await Task.Run(() => Capture(source, control, cutoff));
            byte[] encrypted = await Task.Run(() => TransferCrypto.Encrypt(doc, password));
            // Complete verification before publishing the only portable copy.
            Validate(await Task.Run(() => TransferCrypto.Decrypt(encrypted, password)));
            string temp = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { await f.WriteAsync(encrypted); f.Flush(true); }
                File.Move(temp, destination, false); committed = true;
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
            control.State = "transferred"; control.TransferId = doc.TransferId; control.Save(source);
        }
        catch
        {
            // Once an archive exists, source must remain paused even if the last metadata write failed.
            if (!committed) { original.State = oldState; original.Save(source); }
            throw;
        }
    }
    internal static string LedgerPath(string destination) => destination.TrimEnd(Path.DirectorySeparatorChar) + ".transfers.json";
    internal static void Install(AppHost host, TransferDocument doc)
    {
        Validate(doc);
        string root = host.DataRoot; Storage.RejectReparse(root);
        string ledger = LedgerPath(root);
        var ids = File.Exists(ledger) ? JsonSerializer.Deserialize<List<string>>(File.ReadAllText(ledger)) ?? [] : [];
        if (ids.Contains(doc.TransferId)) throw new UserError("此移轉檔已在這個資料位置匯入過。");
        if (Directory.Exists(root) && Directory.EnumerateFileSystemEntries(root).Any()) throw new UserError("目的資料夾已有資料，不能覆蓋或合併；請使用空白資料位置。");
        string parent = Path.GetDirectoryName(root)!; Directory.CreateDirectory(parent);
        string stage = Path.Combine(parent, ".ldn-import-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        // All restored records are re-encrypted before disk I/O. Incomplete stages are safe to retain for diagnosis.
        foreach (var (path, value) in doc.Records) Storage.ProtectFile(Path.Combine(stage, "state", path.Replace('/', Path.DirectorySeparatorChar)), value);
        Storage.ProtectFile(Path.Combine(stage, "secrets.dat"), Storage.Json(doc.Secrets));
        var config = doc.Config.DeepClone().AsObject(); host.Rebind(config); Storage.WriteObject(Path.Combine(stage, "appsettings.json"), config);
        var control = new Control { DatasetId = doc.DatasetId, State = "stopped", TransferId = doc.TransferId, ResumeAfterUtc = doc.ResumeAfterUtc };
        control.Save(stage);
        if (Directory.Exists(root)) Directory.Delete(root, false); // validated empty, never recursive
        Directory.Move(stage, root); // complete dataset becomes visible atomically
        ids.Add(doc.TransferId); Storage.WriteObject(ledger, ids);
    }
    public async Task Import(string file, string password)
    {
        if (new FileInfo(file).Length > TransferCrypto.MaxBytes + 68) throw new UserError("移轉檔超過容量上限。");
        var doc = await Task.Run(() => TransferCrypto.Decrypt(File.ReadAllBytes(file), password));
        await Task.Run(() => Install(host, doc));
    }
    public static void ResumeSource(string root)
    {
        if (!File.Exists(Path.Combine(root, "appsettings.json"))) throw new UserError("來源資料不存在。");
        var c = Control.Load(root);
        if (c.State is not ("transferred" or "exporting")) throw new UserError("這份資料未處於搬遷狀態。");
        c.State = "stopped"; c.TransferId = null; c.Save(root);
    }
}
