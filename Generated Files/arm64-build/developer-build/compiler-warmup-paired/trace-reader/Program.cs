using System.Text.Json;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using Microsoft.Diagnostics.Tracing;

if (args.Length != 4 || !int.TryParse(args[1], out var expectedPid))
{
    throw new ArgumentException("Expected finalized nettrace, exact compiler PID, new output directory, product root.");
}

if (Directory.Exists(args[2]))
{
    throw new IOException("Refusing to overwrite offline trace evidence.");
}

Directory.CreateDirectory(args[2]);
var productPrefix = Path.GetFullPath(args[3]).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
var pathComparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
var options = new JsonSerializerOptions { WriteIndented = true };
var counts = new Dictionary<string, long>();
var tiers = new Dictionary<string, long>();
var clrInstances = new HashSet<string>();
var modules = new List<object>();
var moduleFiles = new Dictionary<string, object>();
var processes = new HashSet<int>();
var runtimeLevels = new HashSet<string>();
long jitStarts = 0, nativeEntries = 0, instrumentedEntries = 0, optimizedEntries = 0, verboseRecords = 0;
var eventPath = Path.Combine(args[2], "events.jsonl");
using var events = new StreamWriter(eventPath);
using var source = new EventPipeEventSource(args[0]);
// Register CLR templates before inspecting provider/event names. AllEvents
// alone can expose unnamed provider metadata instead of parsed CLR payloads.
source.Clr.All += e =>
{
    if (e.ProviderName != "Microsoft-Windows-DotNETRuntime")
    {
        return;
    }

    processes.Add(e.ProcessID);
    runtimeLevels.Add(e.Level.ToString());
    counts[e.EventName] = counts.GetValueOrDefault(e.EventName) + 1;
    var payload = new Dictionary<string, object?>();
    foreach (var name in e.PayloadNames)
    {
        var value = e.PayloadByName(name);
        payload[name] = value is Enum ? value.ToString() : value;
    }

    if (payload.TryGetValue("ClrInstanceID", out var instance))
    {
        clrInstances.Add(Convert.ToString(instance, System.Globalization.CultureInfo.InvariantCulture)!);
    }

    // Keep raw IDs, timestamps, thread IDs, paths and flags for later offline
    // per-assembly JIT elapsed pairing. These intervals are NOT process CPU.
    var record = new
    {
        e.ProviderName, id = (int)e.ID, e.EventName, e.ProcessID, e.ThreadID,
        e.TimeStampRelativeMSec, timestampUtc = e.TimeStamp.ToUniversalTime(),
        level = e.Level.ToString(), payload
    };
    events.WriteLine(JsonSerializer.Serialize(record));
    if (e.EventName.Contains("ModuleLoad", StringComparison.Ordinal))
    {
        modules.Add(record);
        if (payload.TryGetValue("ModuleILPath", out var pathValue) && pathValue is string path &&
            !moduleFiles.ContainsKey(path))
        {
            // Only inspect files in the explicitly supplied product root.
            // External shadow-cache paths remain loader/PDB metadata, not
            // authority to open arbitrary trace-reported files.
            if (Path.IsPathRooted(path) && Path.GetFullPath(path).StartsWith(productPrefix, pathComparison) && File.Exists(path))
            {
                using var stream = File.OpenRead(path);
                using var pe = new PEReader(stream);
                if (pe.HasMetadata)
                {
                    var metadata = pe.GetMetadataReader();
                    var module = metadata.GetModuleDefinition();
                    var file = new FileInfo(path);
                    moduleFiles[path] = new
                    {
                        path, available = true, mvid = metadata.GetGuid(module.Mvid),
                        file.Length, file.LastWriteTimeUtc,
                        assemblyReferences = metadata.AssemblyReferences.Select(handle =>
                            metadata.GetString(metadata.GetAssemblyReference(handle).Name)).ToArray(),
                        machine = pe.PEHeaders.CoffHeader.Machine.ToString(),
                        managedNativeHeaderBytes = pe.PEHeaders.CorHeader?.ManagedNativeHeaderDirectory.Size,
                        debugDirectories = pe.ReadDebugDirectory().Select(entry => entry.Type.ToString()).ToArray()
                    };
                }
            }
            else
            {
                moduleFiles[path] = new { path, available = false, reason = "Dynamic/external/unavailable module; raw loader and PDB identities retained without opening the path." };
            }
        }
    }

    if (e.EventName.Contains("MethodJittingStarted", StringComparison.Ordinal) ||
        e.EventName.Contains("Method/JittingStarted", StringComparison.Ordinal))
    {
        jitStarts++;
    }

    if (e.EventName == "Method/R2RGetEntryPoint" &&
        payload.TryGetValue("EntryPoint", out var entryPoint) &&
        Convert.ToUInt64(entryPoint, System.Globalization.CultureInfo.InvariantCulture) != 0)
    {
        nativeEntries++;
    }

    // Runtime MethodLoadVerbose payload example:
    // { MethodID, ModuleID, MethodToken, MethodFlags: "Jitted, ...",
    //   ClrInstanceID: 0, ReJITID: 0, OptimizationTier: "QuickJittedInstrumented" }.
    // Decoder releases can expose the tier as an enum or string; keep the raw
    // payload alongside this behavioral summary, never infer from settings 280.
    if (e.EventName.Contains("Method", StringComparison.Ordinal) &&
        e.EventName.Contains("Load", StringComparison.Ordinal) &&
        payload.TryGetValue("OptimizationTier", out var tierValue))
    {
        var tier = Convert.ToString(tierValue, System.Globalization.CultureInfo.InvariantCulture) ?? "";
        tiers[tier] = tiers.GetValueOrDefault(tier) + 1;
        if (tier.Contains("ReadyToRun", StringComparison.OrdinalIgnoreCase))
        {
            nativeEntries++;
        }

        if (tier.Contains("Instrumented", StringComparison.OrdinalIgnoreCase))
        {
            instrumentedEntries++;
        }

        if (tier.Contains("OptimizedTier1", StringComparison.OrdinalIgnoreCase))
        {
            optimizedEntries++;
        }
    }

    if (e.Level == TraceEventLevel.Verbose)
    {
        verboseRecords++;
    }
};
source.Process();
events.Flush();
var passed = source.EventsLost == 0 && processes.SetEquals([expectedPid]) &&
    clrInstances.Count == 1 && modules.Count > 0 && jitStarts > 0 &&
    nativeEntries > 0 && instrumentedEntries > 0 && optimizedEntries > 0 && verboseRecords > 0;
File.WriteAllText(Path.Combine(args[2], "modules.json"), JsonSerializer.Serialize(modules, options));
File.WriteAllText(Path.Combine(args[2], "module-files.json"), JsonSerializer.Serialize(moduleFiles, options));
File.WriteAllText(Path.Combine(args[2], "quality.json"), JsonSerializer.Serialize(new
{
    passed, source.EventsLost, expectedPid, actualPids = processes, clrInstances,
    counts, tiers, runtimeLevels, verboseRecords, jitStarts, nativeEntries,
    instrumentedEntries, optimizedEntries, settings280Required = false,
    cpuOrThreadSampling = false, eventPath,
    interpretation = "Normal-policy behavioral witness, not a throughput or JIT CPU measurement."
}, options));

return passed ? 0 : 1;
