using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LineDutyLauncher;

internal static class SelfTest
{
    internal static int Run(AppHost host, string output)
    {
        var checks = new List<string>(); Directory.CreateDirectory(output);
        string root = Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        void Check(bool value, string name) { if (!value) throw new Exception(name); checks.Add(name); }
        void Reject(Action action, string name) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, name); }
        try
        {
            var config = JsonNode.Parse("""{"TargetGroupNames":["SYNTHETIC_GROUP"],"NotificationDatabase":{"Enabled":true,"DatabasePath":"OLD_MACHINE_PATH","SqlitePath":"OLD_SQLITE"},"Ai":{"Enabled":true,"ApiKeyEnvironmentVariable":"FIXTURE_AI"},"Pushover":{"Enabled":true,"AppTokenEnvironmentVariable":"FIXTURE_APP","UserKeyEnvironmentVariable":"FIXTURE_USER"}}""")!.AsObject();
            string source = Path.Combine(root, "來源 資料"); Directory.CreateDirectory(source); Storage.WriteObject(Path.Combine(source, "appsettings.json"), config);
            var secrets = new Dictionary<string, string> { ["FIXTURE_AI"] = "SECRET_SENTINEL_AI", ["FIXTURE_APP"] = "SECRET_SENTINEL_APP", ["FIXTURE_USER"] = "SECRET_SENTINEL_USER" };
            Storage.ProtectFile(Path.Combine(source, "secrets.dat"), Storage.Json(secrets));
            string owner = """{"Version":1,"People":[{"Id":"owner","IsAdmin":true,"AlwaysOnDuty":true,"LeadMinutes":60,"KeyEnvironment":"FIXTURE_USER"}],"LegacyIds":["old-event"],"LegacyRecipientKey":"SECRET_SENTINEL_USER"}""";
            Storage.ProtectFile(Path.Combine(source, "state", "team", "model.dat"), owner);
            var records = new Dictionary<string, string> {
                ["inbox/event.dat"] = """{"Id":"event","Body":"PRIVATE_SENTINEL_CHAT","ArrivalUtc":"2026-09-01T10:00:00Z"}""",
                ["outbox/pending.dat"] = """{"Status":"pending","Attempts":2,"RecipientId":"owner","Stage":"urgent","ScheduleVersion":3}""",
                ["outbox/accepted.dat"] = """{"Status":"accepted","Receipt":"PRIVATE_SENTINEL_RECEIPT","RecipientId":"owner"}""",
                ["processed/event.dat"] = """{"Status":"done","AiStatus":"confirmed"}""",
                ["usage/count.dat"] = """{"InputTokens":150,"OutputTokens":50,"TotalTokens":200}""",
                ["rosters/roster.dat"] = """{"Status":"published","Data":"IMAGE_SENTINEL"}""",
                ["schedules/schedule.dat"] = """{"Version":3,"Status":"active","Routing":[{"PersonId":"owner","Epoch":2}]}"""
            };
            foreach (var (path, value) in records) Storage.ProtectFile(Path.Combine(source, "state", path.Replace('/', Path.DirectorySeparatorChar)), value);
            Storage.ProtectFile(Path.Combine(source, "state", "health", "Collector.dat"), "{\"Pid\":999}");
            Directory.CreateDirectory(Path.Combine(source, "state", "snapshot")); File.WriteAllText(Path.Combine(source, "state", "snapshot", "omit.db"), "SNAPSHOT_SENTINEL");
            var control = new Control { State = "exporting" }; control.Save(source);
            var cutoff = DateTimeOffset.UtcNow;
            var doc = TransferService.Capture(source, control, cutoff);
            Check(doc.Records.Count == records.Count + 1, "only allowlisted durable records captured");
            Check(!doc.Config.ToJsonString().Contains("OLD_MACHINE"), "source machine paths excluded");
            const string password = "synthetic passphrase 2026";
            byte[] encrypted = TransferCrypto.Encrypt(doc, password);
            Check(!Encoding.UTF8.GetString(encrypted).Contains("SENTINEL"), "archive does not expose plaintext values");
            Reject(() => TransferCrypto.Decrypt(encrypted, "wrong password"), "wrong password rejected");
            byte[] tampered = (byte[])encrypted.Clone(); tampered[^1] ^= 1; Reject(() => TransferCrypto.Decrypt(tampered, password), "ciphertext tampering rejected");
            byte[] header = (byte[])encrypted.Clone(); header[15] ^= 1; Reject(() => TransferCrypto.Decrypt(header, password), "header tampering rejected");
            Reject(() => TransferCrypto.Decrypt(encrypted[..30], password), "truncated archive rejected");
            Reject(() => TransferCrypto.Encrypt(doc, "short"), "short export password rejected");
            var decoded = TransferCrypto.Decrypt(encrypted, password); Check(decoded.DatasetId == control.DatasetId, "dataset identity survives encryption");
            var illegal = TransferCrypto.Decrypt(encrypted, password); illegal.Records["team/../../escape.dat"] = "{}"; Reject(() => TransferService.Validate(illegal), "traversal archive entry rejected");
            illegal = TransferCrypto.Decrypt(encrypted, password); illegal.Version = 2; Reject(() => TransferService.Validate(illegal), "unsupported schema rejected");
            string destination = Path.Combine(root, "目的地 中文 spaces"); var target = new AppHost(host.AppRoot, destination);
            TransferService.Install(target, decoded);
            foreach (var (path, value) in records) Check(Storage.UnprotectFile(Path.Combine(destination, "state", path.Replace('/', Path.DirectorySeparatorChar))) == value, "record preserved: " + path);
            Check(Storage.UnprotectFile(Path.Combine(destination, "state", "team", "model.dat")) == owner, "owner always-on and lead settings preserved");
            Check(Storage.UnprotectFile(Path.Combine(destination, "secrets.dat")).Contains("SECRET_SENTINEL_AI"), "secrets re-encrypted for destination");
            Check(!File.ReadAllText(target.ConfigPath).Contains("SENTINEL_AI"), "settings contain no API key");
            Check(!Directory.Exists(Path.Combine(destination, "state", "health")) && !Directory.Exists(Path.Combine(destination, "state", "snapshot")), "health and DB snapshots not migrated");
            Check(Control.Load(destination).State == "stopped" && Control.Load(destination).ResumeAfterUtc == cutoff, "import stays stopped with scan cutoff");
            var rebound = Storage.ReadObject(target.ConfigPath); Check(rebound["NotificationDatabase"]!["SqlitePath"]!.ToString() == Path.Combine(host.AppRoot, "tools", "sqlite3.exe"), "SQLite rebound to package location");
            Reject(() => TransferService.Install(target, decoded), "repeated import rejected");
            string another = Path.Combine(root, "occupied"); Directory.CreateDirectory(another); File.WriteAllText(Path.Combine(another, "KEEP.txt"), "KEEP");
            Reject(() => TransferService.Install(new AppHost(host.AppRoot, another), decoded), "existing destination refused");
            Check(File.ReadAllText(Path.Combine(another, "KEEP.txt")) == "KEEP", "existing data unchanged after failed import");
            string interrupted = Path.Combine(root, ".ldn-import-interrupted-fixture"); Directory.CreateDirectory(interrupted); Storage.ProtectFile(Path.Combine(interrupted, "secrets.dat"), "{}");
            Check(!File.Exists(Path.Combine(interrupted, "appsettings.json")), "incomplete staging cannot start as active dataset");
            control.State = "transferred"; control.Save(source); TransferService.ResumeSource(source); Check(Control.Load(source).State == "stopped", "explicit source recovery stays stopped");
            PortableIntegration.Run(host, root, Check).GetAwaiter().GetResult();
            Storage.WriteObject(Path.Combine(output, "self-test-result.json"), new { Passed = checks.Count, Checks = checks, Fixture = root, CrossWindowsAccount = "Not run: requires a second Windows account or machine" });
            return 0;
        }
        catch (Exception e) { Storage.WriteObject(Path.Combine(output, "self-test-result.json"), new { Passed = checks.Count, Failed = e.Message, ErrorType = e.GetType().Name, Fixture = root }); return 1; }
    }
}
