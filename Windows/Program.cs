using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Linq;
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
            Text = "拖入一个或多个 BNF、BNL 点读包",
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
                && DroppedPackages(e) is not null)
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
            if (DroppedPackages(e) is { } source)
                await ConvertAsync(source);
        };
        foreach (Control child in control.Controls)
            EnableDrop(child);
    }

    private static string[]? DroppedPackages(DragEventArgs e)
    {
        if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files
            && files.All(path => IsPackage(path) && File.Exists(path)))
            return files;
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
            Multiselect = true,
        };
        if (open.ShowDialog(this) == DialogResult.OK)
            await ConvertAsync(open.FileNames);
    }

    private static string TargetFormat(string source) =>
        Path.GetExtension(source).Equals(".bnf", StringComparison.OrdinalIgnoreCase) ? "bnl" : "bnf";

    private async Task ConvertAsync(string[] paths)
    {
        if (busy || paths.Length == 0)
            return;
        var sources = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        bool batch = sources.Length > 1;
        string? singleOutput = null;
        string folder;
        if (batch)
        {
            using var chooser = new FolderBrowserDialog
            {
                Description = $"为这 {sources.Length} 个点读包选择输出文件夹",
                UseDescriptionForTitle = true,
            };
            if (chooser.ShowDialog(this) != DialogResult.OK)
                return;
            folder = chooser.SelectedPath;
        }
        else
        {
            singleOutput = ChooseDestination(sources[0], TargetFormat(sources[0]));
            if (singleOutput is null)
                return;
            folder = Path.GetDirectoryName(singleOutput)!;
        }

        busy = true;
        pickButton.Enabled = false;
        showOutputButton.Visible = false;
        outputFolder = null;
        var failures = new List<string>();
        try
        {
            for (int index = 0; index < sources.Length; index++)
            {
                string source = sources[index];
                status.Text = $"正在转换 {index + 1}/{sources.Length} · {Path.GetFileName(source)}";
                try
                {
                    string destination = singleOutput ?? BatchDestination(folder, source);
                    await ConvertFileAsync(source, destination);
                }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException)
                {
                    failures.Add($"{Path.GetFileName(source)} · {error.Message}");
                }
            }
            int converted = sources.Length - failures.Count;
            if (converted > 0)
            {
                outputFolder = folder;
                showOutputButton.Visible = true;
            }
            status.Text = batch ? $"已转换 {converted} 个 · 失败 {failures.Count} 个"
                : converted == 1 ? $"已保存 {Path.GetFileName(singleOutput)}" : "转换失败";
            if (failures.Count > 0)
                ShowError(string.Join(Environment.NewLine, failures));
        }
        finally
        {
            busy = false;
            pickButton.Enabled = true;
        }
    }

    private static string BatchDestination(string folder, string source)
    {
        string stem = Path.GetFileNameWithoutExtension(source) + "-音频版";
        string ext = TargetFormat(source);
        for (int number = 1; ; number++)
        {
            string name = number == 1 ? stem : $"{stem} ({number})";
            string path = Path.Combine(folder, $"{name}.{ext}");
            if (!Path.Exists(path) && !Path.Exists($"{path}.conversion.json"))
                return path;
        }
    }

    private string? ChooseDestination(string source, string targetFormat)
    {
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
            return null;

        return save.FileName;
    }

    private static async Task ConvertFileAsync(string source, string destination)
    {
        string targetFormat = TargetFormat(source);
        string sourceFormat = targetFormat == "bnf" ? "bnl" : "bnf";
        string root = AppContext.BaseDirectory;
        string converter = Path.Combine(root, "penconvert.exe");
        string template = Path.Combine(root, "Resources", $"target.{targetFormat}");
        if (!File.Exists(converter) || !File.Exists(template))
            throw new IOException("找不到转换程序或所需模板。请重新解压完整的 Windows 构建包。");

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
