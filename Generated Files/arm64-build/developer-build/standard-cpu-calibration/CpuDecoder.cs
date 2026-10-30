using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection.PortableExecutable;
using System.Text.Json;
using Microsoft.Diagnostics.Symbols;
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
            if (args.Length == 3 && args[0] == "etl-quality")
            {
                InspectEtlQuality(args[1], output);
                return 0;
            }
            if (args.Length == 6 && args[0] == "symbols")
            {
                InspectSymbols(args[1], args[2], args[3], args[4], output);
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
        var touchedModules = new Dictionary<ModuleFileIndex, TraceModuleFile>();
        using var stacks = new StreamWriter(Path.Combine(output, "owned-cpu-stacks.jsonl"));
        using var sampleCoverage = new StreamWriter(Path.Combine(output, "all-owned-sample-coverage.jsonl"));
        foreach (var phase in phases)
        {
            long samples = 0, withStacks = 0, knownMethodSamples = 0, unresolvedFrames = 0, knownStacksWritten = 0;
            long capHits = 0, samplesWithUnresolvedFrames = 0, fullyNamedStacks = 0, leafModuleKnown = 0, leafMethodKnown = 0;
            var maximumWalkedDepth = 0;
            var leafCounts = new Dictionary<string, long>();
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
                var leafModule = stack?.CodeAddress.ModuleName ?? "";
                var leafMethod = stack?.CodeAddress.FullMethodName ?? "";
                var depth = 0;
                var unresolvedInSample = 0;
                if (!string.IsNullOrEmpty(leafModule))
                {
                    leafModuleKnown++;
                }
                if (!string.IsNullOrEmpty(leafMethod))
                {
                    leafMethodKnown++;
                }
                var leafKey = $"{leafModule}!{leafMethod}";
                leafCounts[leafKey] = leafCounts.GetValueOrDefault(leafKey) + 1;
                if (stack is not null)
                {
                    withStacks++;
                }
                for (; stack is not null && depth < 256; stack = stack.Caller, depth++)
                {
                    var code = stack.CodeAddress;
                    var method = code.FullMethodName;
                    var module = code.ModuleName;
                    if (string.IsNullOrEmpty(method))
                    {
                        unresolvedFrames++;
                        unresolvedInSample++;
                    }
                    if (code.ModuleFile is { } moduleFile)
                    {
                        touchedModules[moduleFile.ModuleFileIndex] = moduleFile;
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
                var capped = stack is not null;
                if (capped)
                {
                    capHits++;
                }
                maximumWalkedDepth = Math.Max(maximumWalkedDepth, depth);
                if (unresolvedInSample > 0)
                {
                    samplesWithUnresolvedFrames++;
                }
                if (depth > 0 && unresolvedInSample == 0 && !capped)
                {
                    fullyNamedStacks++;
                }
                sampleCoverage.WriteLine(JsonSerializer.Serialize(new
                {
                    phase = phase.Name, pid = data.ProcessID, timestampUtc = data.TimeStamp.ToUniversalTime(),
                    leafModule, leafMethod, depth, capped, unresolvedFrames = unresolvedInSample
                }));
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
            results.Add(new
            {
                phase.Name, phase.StartUtc, phase.EndUtc, phase.CpuSeconds, samples, withStacks, knownMethodSamples,
                unresolvedFrames, modules, capHits, maximumWalkedDepth, samplesWithUnresolvedFrames, fullyNamedStacks,
                leafModuleKnown, leafMethodKnown, leafCounts
            });
        }
        Save(Path.Combine(output, "owned-module-identities.json"), touchedModules.Values.Select(file => new
        {
            file.FilePath, file.Name, file.ImageBase, file.ImageSize, file.ImageId, file.ImageChecksum,
            file.PdbName, file.PdbSignature, file.PdbAge, file.IsReadyToRun, file.FileVersion,
            file.R2RPerfMapName, file.R2RPerfMapSignature
        }));
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

    private static void InspectEtlQuality(string etl, string output)
    {
        var headers = new List<object>();
        using var source = new ETWTraceEventSource(etl, TraceEventSourceType.FileOnly);
        // This is the public parser for TRACE_LOGFILE_HEADER, not an inferred
        // private collector format. Only session metadata is subscribed.
        // https://learn.microsoft.com/windows/win32/api/evntrace/ns-evntrace-trace_logfile_header
        source.Kernel.EventTraceHeader += header => headers.Add(new
        {
            header.BufferSize, header.BuffersWritten, header.EventsLost, header.BuffersLost,
            header.NumberOfProcessors, header.PerfFreq, header.PointerSize,
            startUtc = header.StartTime.ToUniversalTime(), endUtc = header.EndTime.ToUniversalTime(),
            header.LogFileMode, header.TimerResolution
        });
        var before = source.EventsLost;
        var completed = source.Process();
        var lostCallbacks = new List<object>();
        var strictIndex = Path.Combine(output, "strict.etlx");
        using var conversion = new StreamWriter(Path.Combine(output, "strict-conversion.log"));
        TraceLog.CreateFromEventTraceLogFile(etl, strictIndex, new TraceLogOptions
        {
            ContinueOnError = false, ConversionLog = conversion,
            LocalSymbolsOnly = true, ShouldResolveSymbols = _ => false,
            OnLostEvents = (truncated, lost, count) => lostCallbacks.Add(new { truncated, lost, count })
        });
        using var strict = new TraceLog(strictIndex);
        Save(Path.Combine(output, "etl-quality.json"), new
        {
            input = etl, completed, eventsLostBeforeProcess = before, eventsLostAfterProcess = source.EventsLost,
            headers, strictConversionCompleted = true, strictIndexEventsLost = strict.EventsLost, lostCallbacks,
            scope = "Documented finalized ETW logfile counters, not a universal vendor/internal-loss guarantee"
        });
    }

    private static void InspectSymbols(string input, string identityPath, string phasesPath, string localSdk, string output)
    {
        var identity = JsonSerializer.Deserialize<Identity>(File.ReadAllText(identityPath), s_json)!;
        var phases = JsonSerializer.Deserialize<Phase[]>(File.ReadAllText(phasesPath), s_json)!;
        // Symbol lookup mutates the in-memory address table; isolate its backing
        // input too so the original failed run/index cannot be retrofitted.
        var copy = Path.Combine(output, "owned-input.etlx");
        File.Copy(input, copy);
        using var log = new TraceLog(copy);
        var candidates = log.Processes.Where(p => p.ProcessID == identity.Pid &&
            p.StartTime.ToUniversalTime() <= phases.Max(x => x.EndUtc) &&
            p.EndTime.ToUniversalTime() >= phases.Min(x => x.StartUtc)).ToArray();
        if (candidates.Length != 1 ||
            !candidates[0].CommandLine.StartsWith($"\"{identity.ImagePath}\" ", StringComparison.OrdinalIgnoreCase) ||
            !candidates[0].CommandLine.Contains(identity.CommandContains, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Owned PID/path/command identity mismatch.");
        }
        var modules = new Dictionary<ModuleFileIndex, TraceModuleFile>();
        var samples = new List<SymbolSample>();
        foreach (var phase in phases)
        {
            foreach (var data in log.Events.FilterByTime(phase.StartUtc.ToLocalTime(), phase.EndUtc.ToLocalTime()))
            {
                if (data.ProcessID != identity.Pid || data is not SampledProfileTraceData)
                {
                    continue;
                }
                var addresses = new List<CodeAddressIndex>();
                var stack = data.CallStack();
                for (var depth = 0; stack is not null && depth < 256; stack = stack.Caller, depth++)
                {
                    addresses.Add(stack.CodeAddress.CodeAddressIndex);
                    if (stack.CodeAddress.ModuleFile is { } module)
                    {
                        modules[module.ModuleFileIndex] = module;
                    }
                }
                samples.Add(new SymbolSample(phase.Name, data.TimeStamp.ToUniversalTime(), addresses, stack is not null));
            }
        }
        Save(Path.Combine(output, "before.json"), SymbolCoverage(log, samples));
        var cache = Path.Combine(output, "symbol-cache");
        Directory.CreateDirectory(cache);
        using var diagnostics = new StreamWriter(Path.Combine(output, "symbol-reader.log")) { AutoFlush = true };
        using var reader = new SymbolReader(diagnostics, $"srv*{cache}*https://msdl.microsoft.com/download/symbols")
        {
            Options = SymbolReaderOptions.NoNGenSymbolCreation
        };
        var results = new List<object>();
        foreach (var module in modules.Values.Where(m => m.Name is "coreclr" or "system.private.corelib"))
        {
            // Only public runtime binaries from this exact private SDK prefix
            // may be mapped to local images. Never search by filename alone or
            // send KnownWork/private PDB identities to a public symbol server.
            const string remotePrefix = @"c:\a\aspire\aspire\instrumentation\.dotnet\";
            if (!module.FilePath.StartsWith(remotePrefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Selected runtime module is outside recorded private SDK.");
            }
            var image = Path.Combine(localSdk, module.FilePath[remotePrefix.Length..]);
            using var stream = File.OpenRead(image);
            using var pe = new PEReader(stream);
            using var publicPe = new PEFile.PEFile(image);
            var hasNativePdb = publicPe.GetPdbSignature(out var pdbName, out var guid, out var age, true);
            var imageIdMatches = pe.PEHeaders.CoffHeader.TimeDateStamp == module.ImageId;
            var imageSizeMatches = pe.PEHeaders.PEHeader!.SizeOfImage == module.ImageSize;
            var checksumMatches = pe.PEHeaders.PEHeader.CheckSum == (uint)module.ImageChecksum;
            var pdbMatches = hasNativePdb && guid == module.PdbSignature && age == module.PdbAge &&
                string.Equals(Path.GetFileName(pdbName), Path.GetFileName(module.PdbName), StringComparison.OrdinalIgnoreCase);
            var verified = imageIdMatches && imageSizeMatches && checksumMatches && pdbMatches;
            var imageIdentity = new
            {
                module.Name, tracePath = module.FilePath, localImage = image,
                traceImageId = module.ImageId, localImageId = pe.PEHeaders.CoffHeader.TimeDateStamp,
                traceImageSize = module.ImageSize, localImageSize = pe.PEHeaders.PEHeader.SizeOfImage,
                traceChecksum = module.ImageChecksum, localChecksum = pe.PEHeaders.PEHeader.CheckSum,
                tracePdbName = module.PdbName, tracePdbGuid = module.PdbSignature, tracePdbAge = module.PdbAge,
                localNativePdbName = pdbName, localNativePdbGuid = guid, localNativePdbAge = age,
                imageIdMatches, imageSizeMatches, checksumMatches, pdbMatches, verified,
                traceReadyToRun = module.IsReadyToRun, localReadyToRun = publicPe.IsManagedReadyToRun,
                machine = pe.PEHeaders.CoffHeader.Machine.ToString()
            };
            Save(Path.Combine(output, $"{module.Name}-image-identity.json"), imageIdentity);
            if (!verified)
            {
                results.Add(new { module.Name, attempted = false, reason = "Image/PDB identity mismatch; no filename fallback." });
                continue;
            }
            try
            {
                var path = reader.FindSymbolFilePath(module.PdbName, module.PdbSignature, module.PdbAge, image, module.FileVersion, true);
                if (path is null)
                {
                    results.Add(new { module.Name, attempted = true, found = false, reason = "Exact public PDB lookup returned no file; no native PDB generation." });
                }
                else
                {
                    var symbols = reader.OpenSymbolFile(path);
                    var exactGuid = symbols is not null && symbols.PdbGuid == module.PdbSignature;
                    var exactAge = symbols is NativeSymbolModule native && native.PdbAge == module.PdbAge;
                    results.Add(new
                    {
                        module.Name, attempted = true, found = true, path,
                        readerType = symbols?.GetType().FullName, actualPdbGuid = symbols?.PdbGuid,
                        actualNativePdbAge = (symbols as NativeSymbolModule)?.PdbAge, exactGuid, exactAge
                    });
                    if (exactGuid && exactAge)
                    {
                        // Public TraceEvent mapping uses the exact trace PDB
                        // identity and its normal DIA/RVA lookup. Unsafe matching
                        // and NGEN/crossgen generation remain disabled.
                        log.CodeAddresses.LookupSymbolsForModule(reader, module);
                    }
                }
            }
            catch (Exception exception)
            {
                results.Add(new { module.Name, attempted = true, errorType = exception.GetType().FullName, exception.Message });
                Save(Path.Combine(output, "lookup-results.json"), results);
                diagnostics.WriteLine(exception);
                // A missing native dependency is evidence, not authority to
                // install/register DIA or try another profiling mechanism.
                break;
            }
            Save(Path.Combine(output, "lookup-results.json"), results);
        }
        Save(Path.Combine(output, "lookup-results.json"), results);
        Save(Path.Combine(output, "after.json"), SymbolCoverage(log, samples));
        using var exported = new StreamWriter(Path.Combine(output, "all-owned-symbolized-samples.jsonl"));
        foreach (var sample in samples)
        {
            exported.WriteLine(JsonSerializer.Serialize(new
            {
                pid = identity.Pid, sample.Phase, sample.Timestamp, sample.Capped,
                frames = sample.Addresses.Select(index => new
                {
                    module = log.CodeAddresses[index].ModuleName,
                    method = log.CodeAddresses[index].FullMethodName,
                    address = $"0x{log.CodeAddresses[index].Address:X}"
                })
            }));
        }
        Save(Path.Combine(output, "scope.json"), new
        {
            pid = identity.Pid, sampleCount = samples.Count, phases, privateCache = cache,
            publicRuntimeLookupsOnly = true, unsafePdbMatching = log.CodeAddresses.UnsafePDBMatching,
            nativePdbGeneration = false,
            clrjit = modules.Values.Any(m => m.Name == "clrjit") ? "present" : "not sampled; unmeasured, not failed"
        });
    }

    private static object SymbolCoverage(TraceLog log, List<SymbolSample> samples)
    {
        var modules = samples.SelectMany(s => s.Addresses).GroupBy(i => log.CodeAddresses[i].ModuleName)
            .Select(group => new
            {
                module = group.Key, inclusiveFrames = group.Count(),
                namedFrames = group.Count(index => !string.IsNullOrEmpty(log.CodeAddresses[index].FullMethodName))
            }).ToArray();
        return new
        {
            samples = samples.Count,
            stacksPresent = samples.Count(s => s.Addresses.Count > 0),
            capHits = samples.Count(s => s.Capped),
            maxDepth = samples.Count == 0 ? 0 : samples.Max(s => s.Addresses.Count),
            leafModulesKnown = samples.Count(s => s.Addresses.Count > 0 && !string.IsNullOrEmpty(log.CodeAddresses[s.Addresses[0]].ModuleName)),
            leafMethodsKnown = samples.Count(s => s.Addresses.Count > 0 && !string.IsNullOrEmpty(log.CodeAddresses[s.Addresses[0]].FullMethodName)),
            fullyNamedStacks = samples.Count(s => s.Addresses.Count > 0 && !s.Capped && s.Addresses.All(i => !string.IsNullOrEmpty(log.CodeAddresses[i].FullMethodName))),
            samplesWithUnresolvedFrames = samples.Count(s => s.Addresses.Any(i => string.IsNullOrEmpty(log.CodeAddresses[i].FullMethodName))),
            modules,
            scope = "All owned CPU samples only; inclusive frame counts are not exclusive CPU ownership"
        };
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
    private sealed record SymbolSample(string Phase, DateTime Timestamp, List<CodeAddressIndex> Addresses, bool Capped);
}
