#Requires -Version 7.0

function Test-WslUnassignedDriveLetter {
    param([AllowNull()]$Value)
    # Get-Partition uses System.Char NUL for an unassigned MSFT_Partition.
    # Do not coerce numbers, arrays, whitespace or NUL-containing strings.
    return ($null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0) -or
        ($Value -is [char] -and [int]$Value -eq 0))
}

function Assert-WslDiskHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Disks,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Partitions
    )
    if ($Identity.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($Identity.serial) -or
        [string]::IsNullOrWhiteSpace($Identity.model) -or $Identity.diskBytes -le 0 -or
        $Identity.partitionBytes -le 0 -or $Identity.partitionStartSectors -le 0 -or
        $Identity.partitionSectors * 512 -ne $Identity.partitionBytes) {
        throw 'Expected complete configured hardware and GPT identity.'
    }
    $matching = @($Disks | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.SerialNumber) -and $_.SerialNumber.Trim() -ceq $Identity.serial -and $_.FriendlyName -ceq $Identity.model -and $_.Size -eq $Identity.diskBytes
    })
    if ($matching.Count -ne 1) { throw 'Physical disk hardware identity is missing or ambiguous.' }
    $disk = $matching[0]
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.BusType.ToString() -cne 'USB' -or $disk.PartitionStyle.ToString() -cne 'GPT') {
        throw 'Configured disk is not the expected independent USB GPT device.'
    }
    $rows = @($Partitions | Where-Object { $_.DiskNumber -eq $disk.Number })
    if ($rows.Count -ne 1) { throw 'Configured physical disk must have exactly its approved partition.' }
    $partition = $rows[0]
    if ($partition.Size -ne $Identity.partitionBytes -or $partition.Offset -ne $Identity.partitionStartSectors * 512 -or
        [Guid]$partition.Guid -ne [Guid]$Identity.partitionUuid -or
        [Guid]$partition.GptType -ne [Guid]'0fc63daf-8483-4772-8e79-3d69d8477de4' -or
        -not (Test-WslUnassignedDriveLetter $partition.DriveLetter)) {
        throw 'Windows GPT geometry or partition identity differs from the approved disk.'
    }
    return $disk
}

# Shared system Storage identity resolver; read-only, no disk selection/write.
function Resolve-WslColdStorageNestedPath {
    param([string]$ManifestPath,[string]$Relative)
    # The selected system manifest currently declares direct files. Refuse
    # other grammars instead of resolving a module name through PSModulePath.
    if(-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.Contains('\') -or $Relative.Contains('/') -or [IO.Path]::GetExtension($Relative) -cnotin @('.cdxml','.psm1')){throw 'Storage nested declaration must be a direct CDXML/script file.'}
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) $Relative))
}
function Get-WslColdStorageLiteralDeclaration {
    param([string]$ManifestPath)
    if([IO.FileInfo]::new($ManifestPath).Length -gt 1MB){throw 'Storage manifest size refused.'}
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($ManifestPath,[ref]$tokens,[ref]$errors)
    if($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.EndBlock.Statements.Count -ne 1){throw 'Storage manifest must contain one data table.'}
    $statement=$ast.EndBlock.Statements[0]
    if($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or $statement.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or $statement.PipelineElements[0].Expression -isnot [Management.Automation.Language.HashtableAst]){throw 'Storage manifest data table required.'}
    $result=@{}
    foreach($pair in $statement.PipelineElements[0].Expression.KeyValuePairs){
        $key=$pair.Item1.SafeGetValue()
        if($key -iin @('GUID','ModuleVersion','NestedModules')){
            if($result.ContainsKey($key)){throw 'Duplicate Storage identity/declaration field.'}
            # Evaluate only literal identity/declaration nodes. A real module
            # manifest may use supported expressions in OTHER fields (e.g.
            # RequiredAssemblies); never evaluate those as arbitrary code here.
            $result[$key]=$pair.Item2.SafeGetValue()
        }
    }
    if($result.Count -ne 3){throw 'Literal Storage identity and nested declaration required.'}
    return $result
}
function Assert-WslColdStorageCommandBinding {
    param($Parent,[string]$ManifestPath,[guid]$ManifestGuid,[version]$ManifestVersion,[string[]]$NestedPaths,[string]$Name,[object[]]$Resolved)
    $base=[IO.Path]::GetDirectoryName($ManifestPath)
    if(-not $Parent -or $Parent.Name -cne 'Storage' -or $Parent.ModuleType.ToString() -cne 'Manifest' -or -not [string]::Equals($Parent.Path,$ManifestPath,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($Parent.ModuleBase,$base,[StringComparison]::OrdinalIgnoreCase) -or $Parent.Guid -ne $ManifestGuid -or $Parent.Version -ne $ManifestVersion){throw 'Selected Storage manifest identity differs from imported parent.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($nested in @($Parent.NestedModules)){
        if(-not $nested.Path -or -not $seen.Add($nested.Path) -or $NestedPaths -inotcontains $nested.Path){throw 'Imported Storage nested module was not declared by selected manifest.'}
        $kind=if([IO.Path]::GetExtension($nested.Path) -ceq '.cdxml'){'Cim'}else{'Script'}
        if(-not [string]::Equals([IO.Path]::GetDirectoryName($nested.Path),$base,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($nested.ModuleBase,$base,[StringComparison]::OrdinalIgnoreCase) -or $nested.Name -cne [IO.Path]::GetFileNameWithoutExtension($nested.Path) -or $nested.ModuleType.ToString() -cne $kind){throw 'Imported Storage nested path/name/type differs from declaration.'}
    }
    if($seen.Count -ne $NestedPaths.Count){throw 'Storage declared/imported nested inventory differs.'}
    if($Resolved.Count -ne 1){throw ('Ambiguous or shadowed Storage command: '+$Name)}
    $command=$Resolved[0];$origin=@($Parent.NestedModules|Where-Object {[object]::ReferenceEquals($_,$command.Module)})
    $export=$Parent.ExportedCommands[$Name]
    # Real CDXML Get-Command returns a different FunctionInfo wrapper. Its
    # compiled ScriptBlock ID, definition and module context remain identical.
    # Bind that executable identity, never just a wrapper name or file path.
    $codeBound=$export -and $command.ScriptBlock -and $export.ScriptBlock -and $command.ScriptBlock.Id -and ([guid]$command.ScriptBlock.Id -ne [guid]::Empty) -and $command.ScriptBlock.Id -eq $export.ScriptBlock.Id -and $command.Definition -ceq $export.Definition -and [string]::Equals($command.ScriptBlock.Module.Path,$command.Module.Path,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($export.ScriptBlock.Module.Path,$command.Module.Path,[StringComparison]::OrdinalIgnoreCase)
    if($command.Name -cne $Name -or $command.CommandType.ToString() -cne 'Function' -or $origin.Count -ne 1 -or [IO.Path]::GetExtension($origin[0].Path) -cne '.cdxml' -or $command.ModuleName -cne $origin[0].Name -or -not $codeBound){
        $detail=[ordered]@{name=$command.Name;type=$command.CommandType.ToString();moduleName=$command.ModuleName;modulePath=$command.Module.Path;moduleGuid=[string]$command.Module.Guid;moduleVersion=[string]$command.Module.Version;originReferences=$origin.Count;exportReference=[object]::ReferenceEquals($command,$export);exportModule=$export.Module.Path;scriptId=[string]$command.ScriptBlock.Id;exportScriptId=[string]$export.ScriptBlock.Id;scriptModule=$command.ScriptBlock.Module.Path;exportScriptModule=$export.ScriptBlock.Module.Path;scriptFile=$command.ScriptBlock.File;exportScriptFile=$export.ScriptBlock.File;definitionEqual=($command.Definition -ceq $export.Definition)}
        throw ('Storage command is not the selected manifest CDXML export: '+$Name+'; '+(ConvertTo-Json -InputObject $detail -Compress))
    }
}
function Get-WslColdMicrosoftStorageFile {
    param([string]$Path)
    [void](Assert-WslColdProtectedPath $Path)
    $signature=Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    # Publisher identity, not a machine-specific file/certificate hash. Other
    # publisher forms require review, even if the local trust store accepts them.
    $subjects=@('CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US','CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US')
    if($signature.Status.ToString() -cne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cnotin $subjects){throw ('Valid Microsoft Storage signature required: '+$Path)}
    return [ordered]@{path=$Path;sha256=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();signer=$signature.SignerCertificate.Subject}
}
function Get-WslColdStoragePreflight {
    if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Read-only Storage preflight requires native 64-bit PowerShell on Windows.'}
    $manifest=[IO.Path]::GetFullPath((Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/Modules/Storage/Storage.psd1'))
    $files=[Collections.Generic.List[object]]::new();$files.Add((Get-WslColdMicrosoftStorageFile $manifest))
    $data=Get-WslColdStorageLiteralDeclaration $manifest
    $declarations=@($data.NestedModules)
    if($declarations.Count -lt 1 -or $declarations.Count -gt 128){throw 'Bounded declared Storage nested inventory required.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in $declarations){
        if($relative -isnot [string]){throw 'Unsupported Storage nested module specification.'}
        $path=Resolve-WslColdStorageNestedPath $manifest $relative
        if(-not $paths.Add($path)){throw 'Duplicate Storage nested declaration.'};$files.Add((Get-WslColdMicrosoftStorageFile $path))
    }
    foreach($loaded in @(Microsoft.PowerShell.Core\Get-Module -Name Storage -All)){
        if(-not [string]::Equals($loaded.Path,$manifest,[StringComparison]::OrdinalIgnoreCase)){throw 'Ambient Storage module differs from selected system manifest; fresh process required.'}
    }
    # Microsoft's signed manifest uses windir for its system assembly. Refuse
    # an ambient redirection; do not inject/repair environment values.
    if(-not $env:windir -or -not [string]::Equals([IO.Path]::GetFullPath($env:windir),[IO.Path]::GetDirectoryName([Environment]::SystemDirectory),[StringComparison]::OrdinalIgnoreCase)){throw 'Storage system assembly environment differs from native Windows directory.'}
    $parents=@(Microsoft.PowerShell.Core\Import-Module -Name $manifest -PassThru -Global -NoClobber -ErrorAction Stop)
    if($parents.Count -ne 1){throw 'Exactly one selected Storage parent required.'};$parent=$parents[0]
    $commands=[Collections.Generic.List[object]]::new()
    foreach($name in @('Get-DiskImage','Get-Disk','Get-Partition','Initialize-Disk','New-Partition','Format-Volume','Get-Volume')){
        $resolved=@(Microsoft.PowerShell.Core\Get-Command -Name ('Storage\'+$name) -All -ListImported -ErrorAction Stop)
        Assert-WslColdStorageCommandBinding $parent $manifest ([guid]$data.GUID) ([version]$data.ModuleVersion) @($paths) $name $resolved
        $commands.Add([ordered]@{name=$name;moduleName=$resolved[0].ModuleName;modulePath=$resolved[0].Module.Path;commandType=$resolved[0].CommandType.ToString()})
    }
    return [ordered]@{profile='microsoft-system-storage-cdxml-v1';readOnly=$true;manifest=$manifest;guid=$parent.Guid.ToString();version=$parent.Version.ToString();files=@($files);commands=@($commands);diskCommandsExecuted=$false;volumeAccepted=$false;productionAccepted=$false}
}
function Assert-WslSyntheticCParent {
    param([string]$Path)
    if(-not $IsWindows -or [IO.Path]::GetFullPath($Path) -cne $Path -or -not $Path.StartsWith('C:\',[StringComparison]::Ordinal) -or $Path -ceq 'C:\'){throw 'Canonical protected non-root C synthetic parent required.'}
    [void](Assert-WslColdProtectedPath $Path -Directory -PrivateData)
}
