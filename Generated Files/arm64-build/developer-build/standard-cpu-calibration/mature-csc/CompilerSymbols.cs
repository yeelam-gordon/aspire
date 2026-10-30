using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Microsoft.Diagnostics.Symbols;

var sdk = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
if (Directory.Exists(output))
{
    throw new IOException("Refusing compiler symbol probe overwrite.");
}
Directory.CreateDirectory(output);
var results = new List<object>();
using var diagnostics = new StreamWriter(Path.Combine(output, "symbol-reader.log")) { AutoFlush = true };
var cache = Path.Combine(output, "cache");
Directory.CreateDirectory(cache);
using var reader = new SymbolReader(diagnostics, $"srv*{cache}*https://msdl.microsoft.com/download/symbols")
{
    Options = SymbolReaderOptions.NoNGenSymbolCreation
};
foreach (var relative in new[]
{
    @"sdk\11.0.100-rc.2.26504.105\Roslyn\bincore\Microsoft.CodeAnalysis.dll",
    @"sdk\11.0.100-rc.2.26504.105\Roslyn\bincore\Microsoft.CodeAnalysis.CSharp.dll",
    @"shared\Microsoft.NETCore.App\11.0.0-rc.2.26504.105\clrjit.dll"
})
{
    var image = Path.Combine(sdk, relative);
    using var pe = new PEFile.PEFile(image);
    var hasIdentity = pe.GetPdbSignature(out var name, out var guid, out var age, true);
    string? path = null;
    string? error = null;
    bool? matched = null;
    try
    {
        if (hasIdentity)
        {
            path = reader.FindSymbolFilePath(name, guid, age, image);
            if (path is not null)
            {
                var pdb = reader.OpenSymbolFile(path);
                matched = pdb is NativeSymbolModule native && native.PdbGuid == guid && native.PdbAge == age;
            }
        }
    }
    catch (Exception exception)
    {
        error = exception.ToString();
    }
    results.Add(new
    {
        image, readyToRun = pe.IsManagedReadyToRun, hasIdentity, pdbName = name, pdbGuid = guid, pdbAge = age,
        path, matched, error,
        claim = "Local exact image/PDB availability only. Future ETL module image ID/size/checksum/GUID/age must match; no CPU coverage inferred."
    });
    File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
}
