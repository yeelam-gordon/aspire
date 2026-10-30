using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Build.Framework;
using Microsoft.Build.Logging;

var tasks = new List<object>();
var starts = new Dictionary<string, TaskStartedEventArgs>();
var targets = new Dictionary<string, string>();
var serverMessages = new Dictionary<string, List<string>>();
var commands = new Dictionary<string, string>();
var diagnostics = new List<object>();
var successful = false;
var replay = new BinaryLogReplayEventSource();
string Key(BuildEventContext context) => $"{context.NodeId}:{context.ProjectContextId}:{context.TargetId}:{context.TaskId}";
string TargetKey(BuildEventContext context) => $"{context.NodeId}:{context.ProjectContextId}:{context.TargetId}";
replay.TargetStarted += (_, e) => targets[TargetKey(e.BuildEventContext!)] = e.TargetName;
replay.TaskStarted += (_, e) =>
{
    if (e.TaskName == "Csc")
    {
        starts.Add(Key(e.BuildEventContext!), e);
    }
};
replay.MessageRaised += (_, e) =>
{
    if (e is TaskCommandLineEventArgs command)
    {
        commands[Key(command.BuildEventContext!)] = command.CommandLine;
    }
    // Standard Roslyn message: "CompilerServer: server - server processed compilation - ...".
    if (e.BuildEventContext is { } context && e.Message is { } message &&
        message.Contains("CompilerServer:", StringComparison.Ordinal))
    {
        var key = Key(context);
        if (!serverMessages.TryGetValue(key, out var messages))
        {
            messages = [];
            serverMessages.Add(key, messages);
        }
        messages.Add(message);
    }
};
replay.TaskFinished += (_, e) =>
{
    if (e.TaskName == "Csc")
    {
        var start = starts[Key(e.BuildEventContext!)];
        var commandLine = commands.GetValueOrDefault(Key(e.BuildEventContext!)) ?? "";
        // Standard Csc command shape: /analyzer:path or /analyzer:"path with spaces".
        var analyzerPaths = Regex.Matches(commandLine, @"/analyzer:(?:""(?<path>[^""]+)""|(?<path>\S+))")
            .Select(m => m.Groups["path"].Value).Order(StringComparer.Ordinal).ToArray();
        tasks.Add(new
        {
            project = start.ProjectFile, target = targets.GetValueOrDefault(TargetKey(start.BuildEventContext!)),
            commandLine, analyzerPaths,
            compilerServerMessages = serverMessages.GetValueOrDefault(Key(start.BuildEventContext!)) ?? [],
            startedRaw = start.Timestamp.ToString("O"), finishedRaw = e.Timestamp.ToString("O"),
            startKind = start.Timestamp.Kind.ToString(), endKind = e.Timestamp.Kind.ToString(),
            startedUtc = start.Timestamp.ToUniversalTime(), finishedUtc = e.Timestamp.ToUniversalTime(),
            wallSeconds = (e.Timestamp - start.Timestamp).TotalSeconds, succeeded = e.Succeeded
        });
        starts.Remove(Key(e.BuildEventContext!));
    }
};
replay.WarningRaised += (_, e) => diagnostics.Add(new { kind = "warning", e.Code, e.Message, e.File, e.LineNumber });
replay.ErrorRaised += (_, e) => diagnostics.Add(new { kind = "error", e.Code, e.Message, e.File, e.LineNumber });
replay.BuildFinished += (_, e) => successful = e.Succeeded;
replay.Replay(args[0]);
File.WriteAllText(args[1], JsonSerializer.Serialize(new
{
    successful, cscCount = tasks.Count, unfinishedCscCount = starts.Count, diagnostics, tasks,
    replayTimezone = TimeZoneInfo.Local.Id,
    timestampPolicy = "Replay on the same runner/timezone as build; raw Kind/timestamp retained. Csc window is not request-exclusive server CPU."
}, new JsonSerializerOptions { WriteIndented = true }));
return successful && starts.Count == 0 ? 0 : 1;
