using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;

internal static class CpuDecoder
{
    private static readonly JsonSerializerOptions s_json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static int Main(string[] args)
    {
        var output = Path.GetFullPath(args.Last());
        if (Directory.Exists(output))
        {
            throw new IOException("Refusing decoder evidence overwrite.");
        }
        Directory.CreateDirectory(output);
        try
        {
            if (args.Length == 2 && args[0] == "archive-tests")
            {
                ArchiveTests(output);
                return 0;
            }
            if (args.Length != 4)
            {
                throw new ArgumentException("Expected ETL/diagsession, owned identity JSON, phase JSON, new output directory.");
            }
            return Decode(args[0], args[1], args[2], output);
        }
        catch (Exception exception)
        {
            Save(Path.Combine(output, "failure.json"), new { type = exception.GetType().FullName, exception.Message, exception.StackTrace });
            return 1;
        }
    }

    private static int Decode(string input, string identityPath, string phasesPath, string output)
    {
        var identity = JsonSerializer.Deserialize<Identity>(File.ReadAllText(identityPath), s_json)!;
        var phases = JsonSerializer.Deserialize<Phase[]>(File.ReadAllText(phasesPath), s_json)!;
        if (identity.Pid <= 0 || string.IsNullOrEmpty(identity.ImagePath) || string.IsNullOrEmpty(identity.CommandContains) ||
            phases.Length == 0 || phases.Any(p => p.EndUtc <= p.StartUtc))
        {
            throw new ArgumentException("An exact owned PID/path/command anchor and finite phase windows are required.");
        }
        var etl = Path.GetFullPath(input);
        using var conversionLog = new StreamWriter(Path.Combine(output, "conversion.log"));
        if (input.EndsWith(".diagsession", StringComparison.OrdinalIgnoreCase) || input.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            // Public TraceEvent 3.1.28 handles GUID\symcache and GUID\pdbcache.
            // Zero/multiple ETLs fail explicitly; do not guess which CPU stream to select.
            // https://github.com/microsoft/perfview/blob/5fc5e080bc57237df3371def6946275b7c6552a9/src/TraceEvent/ZippedETL.cs
            etl = Path.Combine(output, "expanded.etl");
            new ZippedETLReader(input, conversionLog)
            {
                EtlFileName = etl,
                SymbolDirectory = Path.Combine(output, "symbols")
            }.UnpackArchive();
        }
        var lostCallbacks = new List<object>();
        var etlx = etl.EndsWith(".etlx", StringComparison.OrdinalIgnoreCase) ? etl : Path.Combine(output, "owned-recording.etlx");
        if (etlx != etl)
        {
            TraceLog.CreateFromEventTraceLogFile(etl, etlx, new TraceLogOptions
            {
                ConversionLog = conversionLog,
                ContinueOnError = true,
                LocalSymbolsOnly = true,
                ShouldResolveSymbols = _ => false,
                OnLostEvents = (truncated, lost, count) => lostCallbacks.Add(new { truncated, lost, count })
            });
        }
        conversionLog.Flush();
        using var log = new TraceLog(etlx);
        Save(Path.Combine(output, "conversion-quality.json"), new
        {
            log.EventsLost, lostCallbacks, reusedOwnedEtlx = etlx == etl,
            completeAttribution = false, finalCollectorLoss = "unknown; retain source finalization evidence separately"
        });
        var firstUtc = phases.Min(p => p.StartUtc);
        var lastUtc = phases.Max(p => p.EndUtc);
        var candidates = log.Processes.Where(p => p.ProcessID == identity.Pid &&
            p.StartTime.ToUniversalTime() <= lastUtc && p.EndTime.ToUniversalTime() >= firstUtc).ToArray();
        if (candidates.Length != 1)
        {
            throw new InvalidDataException("Owned PID lifetime is missing/ambiguous in the requested interval.");
        }
        var process = candidates.Single();
        // Kernel process metadata can contain only "VBCSCompiler.exe". Accept
        // that basename only when the command begins with the exact full EXE:
        //   "C:\a\aspire\aspire\.dotnet\...\VBCSCompiler.exe" "-pipename:..."
        var commandProvesPath = process.CommandLine.StartsWith($"\"{identity.ImagePath}\" ", StringComparison.OrdinalIgnoreCase) ||
            process.CommandLine.StartsWith(identity.ImagePath + " ", StringComparison.OrdinalIgnoreCase);
        var pathMatches = string.Equals(process.ImageFileName, identity.ImagePath, StringComparison.OrdinalIgnoreCase) ||
            (commandProvesPath && string.Equals(Path.GetFileName(process.ImageFileName), Path.GetFileName(identity.ImagePath), StringComparison.OrdinalIgnoreCase));
        var commandMatches = process.CommandLine.Contains(identity.CommandContains, StringComparison.OrdinalIgnoreCase);
        Save(Path.Combine(output, "owned-process.json"), new
        {
            identity.Pid,
            process.ImageFileName,
            process.CommandLine,
            startUtc = process.StartTime.ToUniversalTime(),
            endUtc = process.EndTime.ToUniversalTime(),
            externalBirthUtc = identity.BirthUtc,
            pathMatches,
            commandProvesPath,
            commandMatches,
            birthNote = "Controller verifies live PID/birth/path before attach. A process already alive when ETW starts may have a clamped trace start; no exact birth match is inferred."
        });
        if (!pathMatches || !commandMatches)
        {
            throw new InvalidDataException("Trace PID does not match the retained owned executable/command anchor.");
        }

        var results = new List<object>();
        using var stacks = new StreamWriter(Path.Combine(output, "owned-cpu-stacks.jsonl"));
        foreach (var phase in phases)
        {
            long samples = 0, withStacks = 0, knownMethodSamples = 0, unresolvedFrames = 0, knownStacksWritten = 0;
            var modules = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            foreach (var data in log.Events.FilterByTime(phase.StartUtc.ToLocalTime(), phase.EndUtc.ToLocalTime()))
            {
                // Only real kernel SampledProfile CPU events count. Never synthesize
                // CPU from managed thread-residence/thread-time stack computers.
                if (data.ProcessID != identity.Pid || data is not SampledProfileTraceData)
                {
                    continue;
                }
                samples++;
                var frames = new List<object>();
                var known = false;
                var stack = data.CallStack();
                if (stack is not null)
                {
                    withStacks++;
                }
                for (var depth = 0; stack is not null && depth < 256; stack = stack.Caller, depth++)
                {
                    var code = stack.CodeAddress;
                    var method = code.FullMethodName;
                    var module = code.ModuleName;
                    if (string.IsNullOrEmpty(method))
                    {
                        unresolvedFrames++;
                    }
                    if (!string.IsNullOrEmpty(module))
                    {
                        modules[module] = modules.GetValueOrDefault(module) + 1;
                    }
                    known |= !string.IsNullOrEmpty(identity.KnownMethod) &&
                        method.Contains(identity.KnownMethod, StringComparison.Ordinal) &&
                        module.Contains(identity.Assembly, StringComparison.OrdinalIgnoreCase);
                    frames.Add(new { module, method, address = $"0x{code.Address:X}" });
                }
                if (known)
                {
                    knownMethodSamples++;
                }
                // Keep bounded examples, not gigabytes of repeated stacks from
                // an older owned trace. Counts/quality still cover every sample.
                if (samples <= 32 || (known && knownStacksWritten < 32))
                {
                    stacks.WriteLine(JsonSerializer.Serialize(new
                    {
                        phase = phase.Name, pid = data.ProcessID, data.ThreadID,
                        timestampUtc = data.TimeStamp.ToUniversalTime(), knownMethod = known, frames
                    }));
                    if (known)
                    {
                        knownStacksWritten++;
                    }
                }
            }
            results.Add(new { phase.Name, phase.StartUtc, phase.EndUtc, phase.CpuSeconds, samples, withStacks, knownMethodSamples, unresolvedFrames, modules });
        }
        Save(Path.Combine(output, "cpu.json"), new
        {
            pid = identity.Pid,
            traceEventVersion = typeof(TraceLog).Assembly.GetName().Version!.ToString(),
            source = input,
            decoderReportedEventsLost = log.EventsLost,
            lostCallbacks,
            sampleProfileIntervalMilliseconds = log.SampleProfileInterval.TotalMilliseconds,
            intervalCaveat = "TraceLog header/interval metadata, not proof the interval remained constant throughout.",
            phases = results,
            nativeSymbols = "No network/private symbol resolver; unresolved native frames remain explicit.",
            stackOutput = "At most first 32 samples plus 32 known-method examples per phase; aggregate counts include all matching CPU samples.",
            finalCollectorLoss = "unknown unless independently supplied by the owned finalization receipt; not fabricated zero",
            acceptedAsCompleteAttribution = false,
            interpretation = "Offline CPU sample/stack capability only. Retained P21 recordings remain degraded; no old or new build-cause claim."
        });
        return 0;
    }

    private static void ArchiveTests(string output)
    {
        var results = new List<object>();
        foreach (var count in new[] { 0, 1, 2 })
        {
            var root = Path.Combine(output, $"etl-count-{count}");
            Directory.CreateDirectory(root);
            var archive = Path.Combine(root, "fixture.diagsession");
            using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create))
            {
                for (var i = 0; i < count; i++)
                {
                    using var writer = new StreamWriter(zip.CreateEntry($"agent{i}/sample.etl").Open());
                    writer.Write("synthetic archive plumbing only, not a recording");
                }
                using (var pdb = new StreamWriter(zip.CreateEntry("194BAE98-C4ED-470E-9204-1F9389FC9DC1/symcache/owned.pdb").Open()))
                {
                    pdb.Write("synthetic PDB path");
                }
                using var pdbCache = new StreamWriter(zip.CreateEntry("194BAE98-C4ED-470E-9204-1F9389FC9DC1/pdbcache/owned2.pdb").Open());
                pdbCache.Write("synthetic alternate PDB path");
            }
            var rejected = false;
            try
            {
                new ZippedETLReader(archive, TextWriter.Null)
                {
                    EtlFileName = Path.Combine(root, "expanded.etl"),
                    SymbolDirectory = Path.Combine(root, "symbols")
                }.UnpackArchive();
            }
            catch (ApplicationException) { rejected = true; }
            var passed = rejected == (count != 1);
            if (count == 1)
            {
                passed &= File.ReadAllText(Path.Combine(root, "expanded.etl")) == "synthetic archive plumbing only, not a recording" &&
                    File.ReadAllText(Path.Combine(root, "symbols", "owned.pdb")) == "synthetic PDB path" &&
                    File.ReadAllText(Path.Combine(root, "symbols", "owned2.pdb")) == "synthetic alternate PDB path";
            }
            results.Add(new { etlCount = count, rejected, passed });
            if (!passed)
            {
                throw new InvalidDataException("Public diagsession archive API fixture failed.");
            }
        }
        Save(Path.Combine(output, "archive-tests.json"), new { passed = true, results, actualCpuAgentArchive = false });
    }

    private static void Save(string path, object value)
    {
        File.WriteAllText(path, JsonSerializer.Serialize(value, s_json));
    }

    private sealed record Identity(int Pid, string ImagePath, string CommandContains, DateTime? BirthUtc, string Assembly, string KnownMethod);
    private sealed record Phase(string Name, DateTime StartUtc, DateTime EndUtc, double CpuSeconds);
}
