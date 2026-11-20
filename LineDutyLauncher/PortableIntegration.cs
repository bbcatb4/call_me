using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace LineDutyLauncher;

internal static class PortableIntegration
{
    internal static async Task Run(AppHost package, string root, Action<bool, string> check)
    {
        string data = Path.Combine(root, "五程序 隔離測試"); Directory.CreateDirectory(data);
        var host = new AppHost(package.AppRoot, data);
        var config = Storage.ReadObject(Path.Combine(package.Core, "appsettings.example.json"));
        config["TargetGroupNames"] = new JsonArray("SYNTHETIC_GROUP");
        config["Ai"]!["Enabled"] = false; config["Pushover"]!["Enabled"] = false;
        config["Ai"]!["ApiKeyEnvironmentVariable"] = "LDN_SYNTHETIC_AI";
        config["Pushover"]!["AppTokenEnvironmentVariable"] = "LDN_SYNTHETIC_APP";
        config["Pushover"]!["UserKeyEnvironmentVariable"] = "LDN_SYNTHETIC_USER";
        string db = Path.Combine(data, "synthetic.db"), sqlite = Path.Combine(package.AppRoot, "tools", "sqlite3.exe");
        config["NotificationDatabase"]!["DatabasePath"] = db; config["NotificationDatabase"]!["SqlitePath"] = sqlite;
        Storage.WriteObject(host.ConfigPath, config);
        Storage.ProtectFile(Path.Combine(data, "secrets.dat"), "{\"LDN_SYNTHETIC_USER\":\"uuuuuuuuuuuuuuuuuuuuuuuuuuuuuu\"}");
        var control = new Control { State = "ready", ResumeAfterUtc = DateTimeOffset.UtcNow.AddMinutes(-1) }; control.Save(data);
        string Toast(string text) => Convert.ToHexString(Encoding.UTF8.GetBytes("<toast><visual><binding><text>SYNTHETIC_GROUP</text><text>" + text + "</text></binding></visual></toast>"));
        long before = control.ResumeAfterUtc.Value.UtcDateTime.AddMinutes(-1).ToFileTimeUtc(), after = control.ResumeAfterUtc.Value.UtcDateTime.AddSeconds(1).ToFileTimeUtc();
        var info = new ProcessStartInfo(sqlite) { UseShellExecute = false, CreateNoWindow = true };
        info.ArgumentList.Add(db);
        info.ArgumentList.Add($"CREATE TABLE NotificationHandler(RecordId INTEGER, PrimaryId TEXT); CREATE TABLE Notification([Order] INTEGER, ArrivalTime INTEGER, HandlerId INTEGER, Payload BLOB); INSERT INTO NotificationHandler VALUES(1,'LINE'); INSERT INTO Notification VALUES(1,{before},1,X'{Toast("出勤")}'); INSERT INTO Notification VALUES(2,{after},1,X'{Toast("收到")}');");
        using (var p = Process.Start(info)!) { await p.WaitForExitAsync(); check(p.ExitCode == 0, "isolated SQLite fixture created"); }
        try
        {
            await host.Bridge("initialize");
            var model = JsonNode.Parse(Storage.UnprotectFile(Path.Combine(data, "state", "team", "model.dat")));
            check(model?["People"]?[0]?["AlwaysOnDuty"]?.GetValue<bool>() == true, "PowerShell reads launcher-encrypted owner setup");
            await host.Bridge("start"); await host.Bridge("start");
            bool healthy = false;
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(2000);
                var status = await host.Bridge("status"); var workers = status["Workers"]?.AsArray();
                if (workers?.Count == 5 && workers.All(w => w?["Running"]?.GetValue<bool>() == true)) { healthy = true; break; }
            }
            check(healthy, "five packaged workers running after duplicate start");
            await Task.Delay(2000);
            check(Directory.GetFiles(Path.Combine(data, "state", "inbox"), "*.dat").Length == 1, "first scan ignores historical event before transfer cutoff");
            check(Directory.GetFiles(Path.Combine(data, "state", "outbox"), "*.dat").Length == 0, "synthetic test sends no phone notifications");
            string archive = Path.Combine(root, "integration.ldntransfer");
            await new TransferService(host).Export(data, archive, "integration passphrase 2026");
            check(File.Exists(archive) && Control.Load(data).State == "transferred", "export drains all workers and leaves source transferred");
            var stopped = await host.Bridge("status");
            check(stopped["Workers"]!.AsArray().All(w => w?["Running"]?.GetValue<bool>() == false), "all five workers stopped without force kill");
            var copy = new AppHost(package.AppRoot, Path.Combine(root, "integration imported"));
            await new TransferService(copy).Import(archive, "integration passphrase 2026");
            check(Control.Load(copy.DataRoot).State == "stopped", "file import completes without starting monitoring");
            TransferService.ResumeSource(data);
            // Repeated start after stop: same data identity and processed history survive.
            control = Control.Load(data); control.State = "ready"; control.Save(data);
            await host.Bridge("start"); await Task.Delay(4000); await host.Stop();
            check(Directory.GetFiles(Path.Combine(data, "state", "inbox"), "*.dat").Length == 1, "restart retains deduplication and cutoff");
            // The same durable dataset also supports the shared runtime.
            config = Storage.ReadObject(host.ConfigPath);
            config["Runtime"] = new JsonObject { ["ExecutionMode"] = "SharedHost" };
            Storage.WriteObject(host.ConfigPath, config);
            control = Control.Load(data); control.State = "ready"; control.Save(data);
            await host.Bridge("start"); await host.Bridge("start");
            bool sharedHealthy = false;
            for (int i = 0; i < 25; i++)
            {
                await Task.Delay(2000);
                var status = await host.Bridge("status"); var workers = status["Workers"]?.AsArray();
                if (workers?.Count == 5 && workers.All(w => w?["Status"]?.ToString() == "ok") && status["Runtime"]?["ProcessCount"]?.GetValue<int>() == 2)
                { sharedHealthy = true; break; }
            }
            check(sharedHealthy, "shared packaged runtime: five healthy roles in two processes");
            check(Directory.GetFiles(Path.Combine(data, "state", "inbox"), "*.dat").Length == 1, "mode switch does not replay history");
            string sharedArchive = Path.Combine(root, "shared-integration.ldntransfer");
            await new TransferService(host).Export(data, sharedArchive, "integration passphrase 2026");
            var sharedStopped = await host.Bridge("status");
            check(sharedStopped["Workers"]!.AsArray().All(w => w?["Running"]?.GetValue<bool>() == false), "transfer drains shared host and all runspaces");
            var sharedCopy = new AppHost(package.AppRoot, Path.Combine(root, "shared integration imported"));
            await new TransferService(sharedCopy).Import(sharedArchive, "integration passphrase 2026");
            check(Storage.ReadObject(sharedCopy.ConfigPath)["Runtime"]?["ExecutionMode"]?.ToString() == "SharedHost", "transfer preserves execution mode");
            check(!File.Exists(Path.Combine(sharedCopy.DataRoot, "state", "health", "Host.dat")), "host identities are not transferred to new machine");
        }
        finally { await host.Stop(); }
    }
}
