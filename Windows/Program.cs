using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ReadingPenConverter;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainWindow());
    }
}

internal sealed class MainWindow : Form
{
    private static readonly Color Accent = Color.FromArgb(32, 103, 90);
    private static readonly Color Ink = Color.FromArgb(45, 48, 42);
    private static readonly Color Muted = Color.FromArgb(75, 89, 80);
    private static readonly Color Paper = Color.FromArgb(255, 250, 239);
    private static readonly Color DropHighlight = Color.FromArgb(231, 246, 238);

    private readonly Button pickButton = new()
    {
        Text = "选择点读包…",
        AutoSize = true,
        Padding = new Padding(10, 5, 10, 5),
        Margin = new Padding(0, 0, 8, 0),
        BackColor = Accent,
        ForeColor = Color.White,
        FlatStyle = FlatStyle.Flat,
        UseVisualStyleBackColor = false,
    };

    private readonly Button showOutputButton = new()
    {
        Text = "打开输出文件夹",
        AutoSize = true,
        Padding = new Padding(10, 5, 10, 5),
        Margin = Padding.Empty,
        UseVisualStyleBackColor = true,
        Visible = false,
    };

    private readonly Panel dropPanel = new()
    {
        Dock = DockStyle.Fill,
        Margin = new Padding(0, 16, 0, 16),
        Padding = new Padding(12),
        BackColor = Paper,
    };

    private readonly Label status = new()
    {
        Dock = DockStyle.Fill,
        AutoEllipsis = true,
        ForeColor = Muted,
        TextAlign = ContentAlignment.MiddleLeft,
        Margin = new Padding(0, 8, 0, 0),
        AccessibleName = "转换状态",
    };

    private bool busy;
    private string? outputFolder;

    public MainWindow()
    {
        SuspendLayout();
        Text = "点读包转换";
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(530, 300);
        MinimumSize = new Size(485, 305);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        ForeColor = Ink;

        var dropPrompt = new Label
        {
            Text = "将 BNF 或 BNL 点读包拖到这里",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font(Font.FontFamily, 14, FontStyle.Bold),
            ForeColor = Accent,
        };
        dropPanel.Controls.Add(dropPrompt);
        dropPanel.Paint += (_, e) =>
        {
            var bounds = Rectangle.Inflate(dropPanel.ClientRectangle, -1, -1);
            using var border = new Pen(Color.FromArgb(122, 163, 148))
            {
                DashStyle = DashStyle.Dash,
            };
            e.Graphics.DrawRectangle(border, bounds);
        };

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false,
            Margin = Padding.Empty,
        };
        pickButton.FlatAppearance.BorderSize = 0;
        actions.Controls.Add(pickButton);
        actions.Controls.Add(showOutputButton);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(22),
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        layout.Controls.Add(dropPanel, 0, 0);
        layout.Controls.Add(actions, 0, 1);
        layout.Controls.Add(status, 0, 2);
        Controls.Add(layout);
        AcceptButton = pickButton;

        pickButton.Click += ChoosePackage;
        showOutputButton.Click += ShowOutput;
        EnableDrop(this);
        ResumeLayout(true);
    }

    private void EnableDrop(Control control)
    {
        control.AllowDrop = true;
        control.DragEnter += (_, e) =>
        {
            if (!busy && (e.AllowedEffect & DragDropEffects.Copy) != 0
                && DroppedPackage(e) is not null)
            {
                e.Effect = DragDropEffects.Copy;
                dropPanel.BackColor = DropHighlight;
            }
            else
            {
                e.Effect = DragDropEffects.None;
            }
        };
        control.DragLeave += (_, _) => dropPanel.BackColor = Paper;
        control.DragDrop += async (_, e) =>
        {
            dropPanel.BackColor = Paper;
            if (DroppedPackage(e) is { } source)
                await ConvertAsync(source);
        };
        foreach (Control child in control.Controls)
            EnableDrop(child);
    }

    private static string? DroppedPackage(DragEventArgs e)
    {
        if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: 1 } files
            && IsPackage(files[0]) && File.Exists(files[0]))
            return files[0];
        return null;
    }

    private static bool IsPackage(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is ".bnf" or ".bnl";

    private async void ChoosePackage(object? sender, EventArgs e)
    {
        if (busy)
            return;

        using var open = new OpenFileDialog
        {
            Title = "选择点读包",
            Filter = "点读包 (*.bnf;*.bnl)|*.bnf;*.bnl",
            CheckFileExists = true,
            Multiselect = false,
        };
        if (open.ShowDialog(this) == DialogResult.OK)
            await ConvertAsync(open.FileName);
    }

    private async Task ConvertAsync(string source)
    {
        if (busy || !IsPackage(source))
            return;

        var sourceFormat = Path.GetExtension(source).Equals(".bnf", StringComparison.OrdinalIgnoreCase)
            ? "bnf" : "bnl";
        var targetFormat = sourceFormat == "bnf" ? "bnl" : "bnf";
        var root = AppContext.BaseDirectory;
        var converter = Path.Combine(root, "penconvert.exe");
        var template = Path.Combine(root, "Resources", $"target.{targetFormat}");
        if (!File.Exists(converter) || !File.Exists(template))
        {
            ShowError("找不到转换程序或所需模板。请重新解压完整的 Windows 构建包。");
            return;
        }

        using var save = new SaveFileDialog
        {
            Title = $"保存音频版 {targetFormat.ToUpperInvariant()}",
            Filter = $"{targetFormat.ToUpperInvariant()} 点读包 (*.{targetFormat})|*.{targetFormat}",
            DefaultExt = targetFormat,
            AddExtension = true,
            FileName = $"{Path.GetFileNameWithoutExtension(source)}-音频版.{targetFormat}",
            OverwritePrompt = false,
        };
        save.FileOk += (_, e) =>
        {
            if (!Path.GetExtension(save.FileName).Equals($".{targetFormat}", StringComparison.OrdinalIgnoreCase))
            {
                e.Cancel = true;
                ShowError($"请使用 .{targetFormat} 扩展名保存。");
            }
            else if (File.Exists(save.FileName) || File.Exists($"{save.FileName}.conversion.json"))
            {
                e.Cancel = true;
                ShowError("输出包或转换报告已存在。请选择新的文件名。");
            }
        };
        if (save.ShowDialog(this) != DialogResult.OK)
            return;

        var destination = save.FileName;
        busy = true;
        pickButton.Enabled = false;
        showOutputButton.Visible = false;
        outputFolder = null;
        status.Text = $"正在转换为 {targetFormat.ToUpperInvariant()}…";
        try
        {
            var processInfo = new ProcessStartInfo(converter)
            {
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            processInfo.ArgumentList.Add($"convert-{sourceFormat}-to-{targetFormat}");
            processInfo.ArgumentList.Add(source);
            processInfo.ArgumentList.Add(template);
            processInfo.ArgumentList.Add(destination);
            processInfo.ArgumentList.Add("--audio-only");

            using var process = Process.Start(processInfo)
                ?? throw new InvalidOperationException("无法启动转换程序。");
            var readOutput = process.StandardOutput.ReadToEndAsync();
            var readError = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            await readOutput;
            var error = (await readError).Trim();
            if (process.ExitCode != 0)
                throw new InvalidOperationException(error.Length == 0
                    ? $"转换程序退出（代码 {process.ExitCode}）。"
                    : error);
            if (!File.Exists(destination) || !File.Exists($"{destination}.conversion.json"))
                throw new IOException("转换程序未生成完整的输出文件。");

            outputFolder = Path.GetDirectoryName(destination);
            showOutputButton.Visible = outputFolder is not null;
            status.Text = $"已保存 {Path.GetFileName(destination)}";
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException)
        {
            status.Text = "转换失败";
            ShowError(error.Message);
        }
        finally
        {
            busy = false;
            pickButton.Enabled = true;
        }
    }

    private void ShowOutput(object? sender, EventArgs e)
    {
        if (outputFolder is not { } folder)
            return;
        try
        {
            Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true })?.Dispose();
        }
        catch (Win32Exception error)
        {
            ShowError(error.Message);
        }
    }

    private void ShowError(string message) =>
        MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
}
