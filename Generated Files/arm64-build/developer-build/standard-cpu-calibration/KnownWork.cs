using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;

internal static class KnownWork
{
    private static double s_result;
    private static readonly JsonSerializerOptions s_json = new() { WriteIndented = true };

    public static int Main(string[] args)
    {
        var root = Path.GetFullPath(args.Single());
        using var process = Process.GetCurrentProcess();
        File.WriteAllText(Path.Combine(root, "ready.pending"), JsonSerializer.Serialize(new
        {
            pid = process.Id,
            birthUtc = process.StartTime.ToUniversalTime(),
            birthTicks = process.StartTime.ToUniversalTime().Ticks,
            imagePath = Environment.ProcessPath,
            commandContains = typeof(KnownWork).Assembly.Location,
            assembly = typeof(KnownWork).Assembly.GetName().Name,
            knownMethod = nameof(Burn),
            osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
            processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
            framework = RuntimeInformation.FrameworkDescription,
            coreclrPath = process.Modules.Cast<ProcessModule>().Single(m => m.ModuleName == "coreclr.dll").FileName,
            readyUtc = DateTime.UtcNow,
            stopwatchFrequency = Stopwatch.Frequency
        }, s_json));
        // Publish readiness only after the complete identity payload is closed.
        File.Move(Path.Combine(root, "ready.pending"), Path.Combine(root, "ready.json"));

        if (!Wait(root, "go", TimeSpan.FromSeconds(30)))
        {
            return File.Exists(Path.Combine(root, "end")) ? 0 : 2;
        }

        var phases = new object[4];
        for (var i = 0; i < phases.Length; i++)
        {
            var name = i % 2 == 0 ? nameof(Burn) : nameof(Thread.Sleep);
            var startUtc = DateTime.UtcNow;
            var startTicks = Stopwatch.GetTimestamp();
            var startCpu = process.TotalProcessorTime;
            if (i % 2 == 0)
            {
                Burn(TimeSpan.FromSeconds(2));
            }
            else
            {
                Thread.Sleep(TimeSpan.FromSeconds(2));
            }
            var endCpu = process.TotalProcessorTime;
            var endTicks = Stopwatch.GetTimestamp();
            phases[i] = new
            {
                name,
                startUtc,
                endUtc = DateTime.UtcNow,
                startTicks,
                endTicks,
                elapsedSeconds = (endTicks - startTicks) / (double)Stopwatch.Frequency,
                startCpuSeconds = startCpu.TotalSeconds,
                endCpuSeconds = endCpu.TotalSeconds,
                cpuSeconds = (endCpu - startCpu).TotalSeconds
            };
        }

        File.WriteAllText(Path.Combine(root, "phases.json"), JsonSerializer.Serialize(phases, s_json));
        File.WriteAllText(Path.Combine(root, "done"), "Known work finished; waiting for owned collector finalization.");
        // Keep the managed process alive for collector rundown, without adding CPU work.
        return Wait(root, "end", TimeSpan.FromSeconds(45)) ? 0 : 3;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Burn(TimeSpan duration)
    {
        var timer = Stopwatch.StartNew();
        var value = 0.123;
        while (timer.Elapsed < duration)
        {
            for (var i = 0; i < 10_000; i++)
            {
                value = Math.Sqrt(value + 17.3);
            }
        }
        Volatile.Write(ref s_result, value);
    }

    private static bool Wait(string root, string signal, TimeSpan timeout)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < timeout)
        {
            if (File.Exists(Path.Combine(root, "end")))
            {
                return signal == "end";
            }
            if (File.Exists(Path.Combine(root, signal)))
            {
                return true;
            }
            Thread.Sleep(20);
        }
        return false;
    }
}
