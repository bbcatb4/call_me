using System.Text.Json;
using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace LineDutyNativeBridge;

internal static class Program
{
    private static readonly string SpoolPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LineDutyNotifier", "incoming-notifications.jsonl");
    private static readonly HashSet<uint> ProcessedIds = [];
    private static UserNotificationListener? _listener;

    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        _listener = UserNotificationListener.Current;

        if (args.Contains("--authorize", StringComparer.OrdinalIgnoreCase))
        {
            var status = _listener.RequestAccessAsync().AsTask().GetAwaiter().GetResult();
            MessageBox.Show(
                status == UserNotificationListenerAccessStatus.Allowed
                    ? "已授權讀取 Windows 通知。現在可啟動監測器。"
                    : $"通知讀取未授權：{status}",
                "LINE 出勤通知監測器",
                MessageBoxButtons.OK,
                status == UserNotificationListenerAccessStatus.Allowed ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            return;
        }

        if (_listener.GetAccessStatus() != UserNotificationListenerAccessStatus.Allowed)
        {
            MessageBox.Show("尚未授權讀取 Windows 通知。請先執行 --authorize。", "LINE 出勤通知監測器", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(SpoolPath)!);
        _listener.NotificationChanged += OnNotificationChanged;
        Application.Run();
    }

    private static async void OnNotificationChanged(UserNotificationListener sender, UserNotificationChangedEventArgs args)
    {
        if (args.ChangeKind != UserNotificationChangedKind.Added || !ProcessedIds.Add(args.UserNotificationId)) return;
        try
        {
            var notification = sender.GetNotification(args.UserNotificationId);
            if (notification is null) return;

            var appName = notification.AppInfo.DisplayInfo.DisplayName ?? string.Empty;
            var appId = notification.AppInfo.AppUserModelId ?? string.Empty;
            if (!appName.Contains("LINE", StringComparison.OrdinalIgnoreCase) && !appId.Contains("LINE", StringComparison.OrdinalIgnoreCase)) return;

            var binding = notification.Notification.Visual.GetBinding(KnownNotificationBindings.ToastGeneric);
            var text = binding is null ? string.Empty : string.Join(" ", binding.GetTextElements().Select(element => element.Text));
            if (string.IsNullOrWhiteSpace(text)) return;

            var record = new { id = notification.Id, created = notification.CreationTime, app = appName, text };
            await File.AppendAllTextAsync(SpoolPath, JsonSerializer.Serialize(record) + Environment.NewLine);
        }
        catch (Exception exception)
        {
            await File.AppendAllTextAsync(SpoolPath, JsonSerializer.Serialize(new { error = exception.Message }) + Environment.NewLine);
        }
    }
}
