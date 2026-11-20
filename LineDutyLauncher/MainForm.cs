using System.Text.Json.Nodes;

namespace LineDutyLauncher;

internal sealed class MainForm : Form
{
    private readonly AppHost host;
    private readonly bool preview;
    private bool busy, polling;
    private readonly Label headline = new() { AutoSize = true, Font = new Font("Microsoft JhengHei UI", 22, FontStyle.Bold), ForeColor = Color.FromArgb(22, 62, 99) };
    private readonly Label state = new() { AutoSize = true, MaximumSize = new Size(880, 0), Font = new Font("Microsoft JhengHei UI", 12) };
    private readonly Label note = new() { AutoSize = true, MaximumSize = new Size(880, 0), ForeColor = Color.FromArgb(71, 85, 105) };
    private readonly FlowLayoutPanel actions = new() { AutoSize = false, WrapContents = true, Dock = DockStyle.Fill };
    private readonly ListView workers = new() { View = View.Details, FullRowSelect = true, GridLines = false, Height = 190, Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 5000 };
    internal MainForm(AppHost host, bool preview = false)
    {
        this.host = host; this.preview = preview;
        Text = "LINE 值班通知 · 0.2.0"; Size = new Size(960, 860); MinimumSize = new Size(880, 800); StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft JhengHei UI", 10); BackColor = Color.FromArgb(243, 246, 250);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(26), RowCount = 7, ColumnCount = 1 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (int h in new[] { 58, 68, 128, 210, 62 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, h));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        Controls.Add(layout); headline.Text = "LINE 值班通知"; layout.Controls.Add(headline, 0, 0);
        state.Text = "準備就緒 · 首次使用請完成設定，或匯入加密移轉檔。"; layout.Controls.Add(state, 0, 1); layout.Controls.Add(actions, 0, 2);
        AddButton("啟動監測", () => Run(async () => { await host.Start(); note.Text = "監測已啟動，心跳會在約 30 秒內更新。"; }));
        AddButton("停止監測", () => Run(async () => { await host.Stop(); note.Text = "五個背景程序已安全停止。"; }));
        AddButton("開啟儀表板", () => Run(() => { host.OpenView("Show-NotifierDashboard.ps1"); return Task.CompletedTask; }));
        AddButton("班表與人員", () => Run(() => { host.OpenView("Show-TeamManagement.ps1"); return Task.CompletedTask; }));
        AddButton("首次設定／修改", ShowSettings);
        AddButton("環境檢查", () => Run(CheckEnvironment));
        AddButton("匯出搬遷", Export);
        AddButton("匯入搬遷", Import);
        AddButton("取消搬遷／恢復舊機", Resume);
        workers.Columns.Add("工作程序", 225); workers.Columns.Add("狀態", 150); workers.Columns.Add("說明", 445);
        foreach (string name in new[] { "Windows 收訊", "AI 語意判讀", "班表與排程", "Pushover 推播", "手機確認追蹤" }) workers.Items.Add(new ListViewItem([name, "尚未啟動", "完成設定後，可啟動監測。"]));
        layout.Controls.Add(workers, 0, 3);
        var path = new Label { AutoSize = true, MaximumSize = new Size(880, 0), Text = "個人資料位置：" + (preview ? "%LOCALAPPDATA%\\LineDutyNotifier" : host.DataRoot) + "\n程式資料夾可更換；跨電腦資料請使用加密搬遷。", ForeColor = Color.FromArgb(71, 85, 105) };
        layout.Controls.Add(path, 0, 4); layout.Controls.Add(note, 0, 5);
        layout.Controls.Add(new Label { AutoSize = true, Text = "關閉本視窗不會停止監測。新電腦需登入 LINE，並啟用 Windows 通知。", MaximumSize = new Size(880, 0) }, 0, 6);
        note.Text = "免安裝版 · 本機資料加密保存 · 搬遷成功後舊機保持暫停";
        timer.Tick += async (_, _) => await Poll();
        Shown += async (_, _) => { if (preview) return; timer.Start(); await Poll(); if (!File.Exists(host.ConfigPath)) ShowSettings(); };
        FormClosing += (_, e) => { if (busy) { e.Cancel = true; note.Text = "操作正在完成，請等待結果後再關閉。"; } };
        FormClosed += (_, _) => timer.Dispose();
    }
    private void AddButton(string title, Action action)
    {
        var b = new Button { Text = title, AutoSize = true, Padding = new Padding(10, 7, 10, 7), Margin = new Padding(0, 0, 10, 8), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(22, 62, 99), ForeColor = Color.White };
        b.FlatAppearance.BorderSize = 0; b.Click += (_, _) => action(); actions.Controls.Add(b);
    }
    private async void Run(Func<Task> operation)
    {
        if (busy) return; busy = true; actions.Enabled = false;
        note.Text = "正在處理，請稍候…";
        try { await operation(); }
        catch (UserError e) { note.Text = e.Message; MessageBox.Show(this, e.Message, "需要處理", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        catch { note.Text = "操作未完成，請檢查檔案、網路與目前 Windows 帳號權限；既有資料未被覆蓋。"; }
        finally { busy = false; actions.Enabled = true; await Poll(); }
    }
    private async Task Poll()
    {
        if (preview || polling || busy) return; polling = true;
        try
        {
            if (!File.Exists(host.ConfigPath)) { state.Text = "尚未設定 · 請完成首次設定，或匯入既有資料。"; return; }
            var c = Control.Load(host.DataRoot);
            state.Text = c.State switch { "ready" => "監測已啟用 · 正在核對各程序狀態", "exporting" => "搬遷中／中斷待處理 · 原機保持暫停", "transferred" => "已產生移轉檔 · 原機保持暫停", _ => "監測已停止 · 資料保留，可隨時啟動" };
            var s = await host.Bridge("status"); workers.Items.Clear();
            var labels = new Dictionary<string, string> { ["Collector"] = "Windows 收訊", ["Classifier"] = "AI 語意判讀", ["Scheduler"] = "班表與排程", ["Sender"] = "Pushover 推播", ["Receipts"] = "手機確認追蹤" };
            foreach (var w in s["Workers"]?.AsArray() ?? [])
            {
                string role = w?["Role"]?.ToString() ?? ""; string status = w?["Status"]?.ToString() ?? "unknown";
                string translated = status switch { "ok" => "正常運作", "warning" => "需要留意", "error" => "需要處理", _ => "尚無最新狀態" };
                if (c.State != "ready") translated = w?["Running"]?.GetValue<bool>() == true ? "仍在執行，等待停止" : "已暫停";
                workers.Items.Add(new ListViewItem([labels.GetValueOrDefault(role, role), translated, c.State == "ready" && status != "ok" ? "請開啟儀表板查看心跳與錯誤摘要。" : ""]));
            }
            if (c.State == "ready" && s["Overall"]?.ToString() == "ok") state.Text = "正常運作 · 五個程序與收訊檢查通過";
            if (c.State != "ready" && s["Workers"]!.AsArray().Any(w => w?["Running"]?.GetValue<bool>() == true)) state.Text = "已要求暫停，但仍有程序執行中 · 請完成安全停止後再搬遷";
        }
        catch { state.Text = "目前無法確認狀態，請檢查設定或開啟儀表板。"; }
        finally { polling = false; }
    }
    private async Task CheckEnvironment()
    {
        var c = await host.Bridge("check");
        var labels = new Dictionary<string, string> { ["PowerShell51"] = "Windows PowerShell 5.1", ["Pdf"] = "PDF 預覽元件", ["Sqlite"] = "隨附 SQLite", ["Database"] = "Windows 通知資料庫", ["DatabaseReadable"] = "通知資料庫可讀取", ["LineRunning"] = "LINE 正在執行", ["LineSource"] = "已找到 LINE 通知來源" };
        note.Text = string.Join("\n", labels.Select(x => x.Value + "：" + (c[x.Key]?.GetValue<bool>() == true ? "通過" : "尚未確認"))) + "\n若尚無 LINE 通知來源，請登入 LINE 並讓目標群組產生 Windows 通知，再重新檢查。";
    }
    private void ShowSettings()
    {
        if (busy) return;
        try
        {
            var control = Control.Load(host.DataRoot);
            if (control.State is "ready" or "exporting" or "transferred") throw new UserError("請先停止監測；搬遷中的資料需先取消搬遷，才能修改設定。");
            JsonObject config = File.Exists(host.ConfigPath) ? Storage.ReadObject(host.ConfigPath) : Storage.ReadObject(Path.Combine(host.Core, "appsettings.example.json"));
            using var form = new SettingsForm(config, File.Exists(host.ConfigPath));
            if (form.ShowDialog(this) != DialogResult.OK) return;
            string[] enteredValues = [form.AiKey, form.AppToken, form.UserKey], enteredGroups = form.Groups;
            bool aiEnabled = form.AiEnabled;
            Run(async () =>
            {
                // Drain any workers/UI before settings edits, including after an interrupted shutdown.
                if (File.Exists(host.ConfigPath)) await host.Stop();
                var secrets = AppHost.ReadSecrets(host.DataRoot, config);
                string[] names = AppHost.SecretNames(config); string[] values = enteredValues;
                for (int i = 0; i < 3; i++) if (values[i].Length > 0) secrets[names[i]] = values[i];
                if (aiEnabled && string.IsNullOrWhiteSpace(secrets.GetValueOrDefault(names[0]))) throw new UserError("啟用 AI 時需要 API 金鑰。");
                foreach (string name in names.Skip(1)) if (!System.Text.RegularExpressions.Regex.IsMatch(secrets.GetValueOrDefault(name, ""), "^[a-zA-Z0-9]{30}$")) throw new UserError("Pushover 收件資料與 App Token 必須為 30 位英數字。");
                config["TargetGroupNames"] = new JsonArray(enteredGroups.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
                config["Ai"]!["Enabled"] = aiEnabled; config["Pushover"]!["Enabled"] = true;
                host.Rebind(config); Directory.CreateDirectory(host.DataRoot);
                Storage.ProtectFile(Path.Combine(host.DataRoot, "secrets.dat"), Storage.Json(secrets)); Storage.WriteObject(host.ConfigPath, config);
                control.State = "stopped"; control.ResumeAfterUtc ??= DateTimeOffset.UtcNow; control.Save(host.DataRoot);
                await host.Bridge("initialize");
                note.Text = "設定已加密儲存。你的帳號預設為全時段管理者、提前 60 分鐘提醒。請執行環境檢查，再啟動監測。";
            });
        }
        catch (UserError e) { MessageBox.Show(this, e.Message, "設定"); }
        catch { MessageBox.Show(this, "設定無法讀取，請確認程式資料夾已完整解壓縮。", "設定"); }
    }
    private string? ChooseSource()
    {
        using var dialog = new FolderBrowserDialog { Description = "選擇包含 appsettings.json 與 state 的來源資料夾。既有版本可選原 LineDutyNotifier 資料夾。", SelectedPath = Directory.Exists(host.DataRoot) ? host.DataRoot : "" };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedPath : null;
    }
    private void Export()
    {
        string? source = ChooseSource(); if (source is null) return;
        using var dialog = new SaveFileDialog { Filter = "加密移轉檔|*.ldntransfer", FileName = "LineDutyNotifier-" + DateTime.Now.ToString("yyyyMMdd-HHmm") + ".ldntransfer", OverwritePrompt = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        using var password = new PasswordForm(true); if (password.ShowDialog(this) != DialogResult.OK) return;
        if (MessageBox.Show(this, "請先儲存尚未完成的班表／人員編輯。系統將關閉管理視窗並等待來源監測器安全停止，匯出後來源保持暫停。移轉檔包含金鑰與完整通知資料，請保管好密碼。", "匯出並暫停來源", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        string secret = password.Value, target = dialog.FileName;
        Run(async () => { note.Text = "等待背景工作安全完成；最長約 150 秒…"; await new TransferService(host).Export(source, target, secret); note.Text = "移轉檔已產生，來源保持暫停。將程式 ZIP 與移轉檔帶到新電腦，匯入並檢查後啟動。"; });
    }
    private void Import()
    {
        using var dialog = new OpenFileDialog { Filter = "加密移轉檔|*.ldntransfer" }; if (dialog.ShowDialog(this) != DialogResult.OK) return;
        using var password = new PasswordForm(false); if (password.ShowDialog(this) != DialogResult.OK) return;
        string file = dialog.FileName, secret = password.Value;
        Run(async () => { await new TransferService(host).Import(file, secret); note.Text = "資料已匯入並重新本機加密。請核對人員設定與環境檢查，再按啟動監測。"; });
    }
    private void Resume()
    {
        string? source = ChooseSource(); if (source is null) return;
        if (MessageBox.Show(this, "請先停止接替的新電腦，避免同一份班表重複通知。已確認停止新機，要解除來源搬遷狀態嗎？", "取消搬遷", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        Run(() => { TransferService.ResumeSource(source); note.Text = "已解除來源搬遷狀態，來源目前仍為停止。可從原機啟動器手動啟動。"; return Task.CompletedTask; });
    }
}

internal sealed class SettingsForm : Form
{
    private readonly TextBox groups = new() { Multiline = true, Height = 80, Dock = DockStyle.Fill };
    private readonly TextBox ai = new() { UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly TextBox app = new() { UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly TextBox user = new() { UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly CheckBox enabled = new() { Text = "啟用 AI 語意分析", AutoSize = true };
    public string[] Groups => groups.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct().ToArray();
    public string AiKey => ai.Text.Trim(); public string AppToken => app.Text.Trim(); public string UserKey => user.Text.Trim(); public bool AiEnabled => enabled.Checked;
    public SettingsForm(JsonObject config, bool existing)
    {
        Text = existing ? "修改設定" : "首次設定"; Size = new Size(650, 540); StartPosition = FormStartPosition.CenterParent; Font = new Font("Microsoft JhengHei UI", 10);
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 12, AutoScroll = true };
        Controls.Add(panel);
        panel.Controls.Add(new Label { Text = "LINE 目標群組（每行一個，需與通知標題一致）", AutoSize = true }); panel.Controls.Add(groups);
        panel.Controls.Add(enabled); panel.Controls.Add(new Label { Text = "OpenAI API Key", AutoSize = true }); panel.Controls.Add(ai);
        panel.Controls.Add(new Label { Text = "Pushover App Token", AutoSize = true }); panel.Controls.Add(app);
        panel.Controls.Add(new Label { Text = "你的 Pushover User Key", AutoSize = true }); panel.Controls.Add(user);
        panel.Controls.Add(new Label { Text = "金鑰加密保存在本機。留空保留已儲存值／沿用既有環境變數。", AutoSize = true, MaximumSize = new Size(570, 0) });
        var save = new Button { Text = "儲存設定", AutoSize = true, Padding = new Padding(10), Margin = new Padding(0, 12, 0, 0) };
        save.Click += (_, _) => { if (Groups.Length == 0) { MessageBox.Show(this, "請至少輸入一個群組名稱。"); return; } DialogResult = DialogResult.OK; };
        panel.Controls.Add(save); AcceptButton = save;
        groups.Text = existing ? string.Join(Environment.NewLine, config["TargetGroupNames"]?.AsArray().Select(x => x?.ToString()) ?? []) : "";
        enabled.Checked = existing ? config["Ai"]?["Enabled"]?.GetValue<bool>() == true : true;
    }
}

internal sealed class PasswordForm : Form
{
    private readonly TextBox password = new() { UseSystemPasswordChar = true, Width = 355 };
    private readonly TextBox confirm = new() { UseSystemPasswordChar = true, Width = 355 };
    public string Value => password.Text;
    public PasswordForm(bool exporting)
    {
        Text = exporting ? "設定移轉密碼" : "輸入移轉密碼"; Size = new Size(440, 300); StartPosition = FormStartPosition.CenterParent; Font = new Font("Microsoft JhengHei UI", 10);
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), FlowDirection = FlowDirection.TopDown, WrapContents = false };
        Controls.Add(panel); panel.Controls.Add(new Label { AutoSize = true, Text = exporting ? "至少 12 個字元，請另外保存密碼。" : "輸入匯出時設定的密碼。" }); panel.Controls.Add(password);
        if (exporting) { panel.Controls.Add(new Label { AutoSize = true, Text = "再次輸入密碼" }); panel.Controls.Add(confirm); }
        var ok = new Button { Text = "確定", AutoSize = true };
        ok.Click += (_, _) => { if (password.Text.Length == 0 || (exporting && (password.Text.Length < 12 || password.Text != confirm.Text))) { MessageBox.Show(this, "請檢查密碼長度與兩次輸入是否一致。"); return; } DialogResult = DialogResult.OK; };
        panel.Controls.Add(ok); AcceptButton = ok;
    }
}
