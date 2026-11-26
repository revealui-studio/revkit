BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/lib/WslColdSyntheticVolume.ps1')
    Initialize-WslColdWorkerProtocol
    function SidBytes([uint32]$Last) {return [byte[]](@(1,5,0,0,0,0,0,5)+[BitConverter]::GetBytes([uint32]21)+[BitConverter]::GetBytes([uint32]111)+[BitConverter]::GetBytes([uint32]222)+[BitConverter]::GetBytes([uint32]333)+[BitConverter]::GetBytes($Last))}
    function AclBytes {
        $data=[byte[]]::new(68);$data[0]=2;[BitConverter]::GetBytes([uint16]68).CopyTo($data,2);$data[4]=3
        $at=8
        foreach($sid in @([byte[]](1,1,0,0,0,0,0,1,0,0,0,0),[byte[]](1,1,0,0,0,0,0,3,0,0,0,0),[byte[]](1,1,0,0,0,0,0,5,18,0,0,0))){$data[$at+1]=3;[BitConverter]::GetBytes([uint16]20).CopyTo($data,$at+2);[BitConverter]::GetBytes([uint32]0x1f01ff).CopyTo($data,$at+4);$sid.CopyTo($data,$at+8);$at+=20}
        return ,$data
    }
    function LayoutBytes([int]$Capacity=248,[byte[]]$Tail=$null) {[Revealfleet.Backup.ColdSecurityLayout]::Compose(0x8004,(SidBytes 1001),(SidBytes 513),(AclBytes),$Capacity,$Tail)}
    function New-StorageOwnershipModel {
        $base=Join-Path $TestDrive 'system/Storage';$manifest=Join-Path $base 'Storage.psd1';$path=Join-Path $base 'Disk.cdxml'
        $nested=[pscustomobject]@{Name='Disk';ModuleType='Cim';ModuleBase=$base;Path=$path}
        $command=[pscustomobject]@{Name='Get-Disk';CommandType='Function';ModuleName='Disk';Module=$nested;Definition='param() # modeled compiled function';ScriptBlock=[pscustomobject]@{Id=[guid]::NewGuid();Module=$nested}}
        $parent=[pscustomobject]@{Name='Storage';ModuleType='Manifest';ModuleBase=$base;Path=$manifest;Guid=[guid]'193c8b20-f199-43df-9b86-53ad824ed732';Version=[version]'2.0.0.0';NestedModules=@($nested);ExportedCommands=@{'Get-Disk'=$command}}
        return @{Parent=$parent;ManifestPath=$manifest;ManifestGuid=$parent.Guid;ManifestVersion=$parent.Version;NestedPaths=@($path);Name='Get-Disk';Resolved=@($command)}
    }
}
Describe 'Selected system Storage nested command ownership' {
    It 'reads literal declarations without evaluating other supported manifest expressions' {
        $path=Join-Path $TestDrive 'expressions.psd1'
        [IO.File]::WriteAllText($path,'@{GUID="193c8b20-f199-43df-9b86-53ad824ed732";ModuleVersion="2.0.0.0";NestedModules=@("Disk.cdxml");RequiredAssemblies=@("$env:windir\system32\Microsoft.Windows.Storage.Core.dll")}')
        $data=Get-WslColdStorageLiteralDeclaration $path
        $data.NestedModules|Should -Contain 'Disk.cdxml';$data.ModuleVersion|Should -BeExactly '2.0.0.0';$data.Count|Should -Be 3
        [IO.File]::WriteAllText($path,'@{GUID="193c8b20-f199-43df-9b86-53ad824ed732";ModuleVersion="2.0.0.0";NestedModules=@("$env:windir\Disk.cdxml")}')
        {Get-WslColdStorageLiteralDeclaration $path}|Should -Throw
    }
    It 'accepts modeled declared nested CDXML exports without misidentifying the child as the parent' {
        $binding=New-StorageOwnershipModel
        {Assert-WslColdStorageCommandBinding @binding}|Should -Not -Throw
    }
    It 'accepts copied metadata wrappers only with exact compiled block, body and owner context' {
        $binding=New-StorageOwnershipModel;$binding.Resolved=@($binding.Resolved[0].PSObject.Copy())
        [object]::ReferenceEquals($binding.Resolved[0],$binding.Parent.ExportedCommands['Get-Disk'])|Should -BeFalse
        {Assert-WslColdStorageCommandBinding @binding}|Should -Not -Throw
        foreach($fault in @('block','body','context')){
            $binding=New-StorageOwnershipModel;$binding.Resolved=@($binding.Resolved[0].PSObject.Copy());$binding.Resolved[0].ScriptBlock=$binding.Resolved[0].ScriptBlock.PSObject.Copy()
            switch($fault){
                block {$binding.Resolved[0].ScriptBlock.Id=[guid]::NewGuid()}
                body {$binding.Resolved[0].Definition='param() # altered proxy body'}
                context {$binding.Resolved[0].ScriptBlock.Module=[pscustomobject]@{Path=(Join-Path $TestDrive 'outside/Disk.cdxml')}}
            }
            {Assert-WslColdStorageCommandBinding @binding}|Should -Throw
        }
    }
    It 'rejects forged parent name, manifest path, version and GUID' {
        foreach($field in @('Name','Path','Version','Guid')){
            $binding=New-StorageOwnershipModel
            switch($field){
                Name {$binding.Parent.Name='Imposter'}
                Path {$binding.Parent.Path=Join-Path $TestDrive 'outside/Storage.psd1'}
                Version {$binding.Parent.Version=[version]'9.0.0.0'}
                Guid {$binding.Parent.Guid=[guid]'44444444-4444-4444-4444-444444444444'}
            }
            {Assert-WslColdStorageCommandBinding @binding}|Should -Throw
        }
    }
    It 'rejects undeclared, escaping and renamed nested modules and incomplete inventories' {
        foreach($fault in @('outside','renamed','undeclared','missing','duplicate')){
            $binding=New-StorageOwnershipModel
            switch($fault){
                outside {$binding.Parent.NestedModules[0].Path=Join-Path $TestDrive 'outside/Disk.cdxml';$binding.NestedPaths=@($binding.Parent.NestedModules[0].Path)}
                renamed {$binding.Parent.NestedModules[0].Name='DiskImposter'}
                undeclared {$binding.NestedPaths=@((Join-Path $TestDrive 'system/Storage/Other.cdxml'))}
                missing {$binding.NestedPaths+=Join-Path $TestDrive 'system/Storage/Volume.cdxml'}
                duplicate {$binding.Parent.NestedModules+=@($binding.Parent.NestedModules[0])}
            }
            {Assert-WslColdStorageCommandBinding @binding}|Should -Throw
        }
    }
    It 'rejects shadow commands, aliases and same-name proxies outside the selected executable export' {
        foreach($fault in @('ambiguous','alias','proxy','foreignModule')){
            $binding=New-StorageOwnershipModel;$original=$binding.Resolved[0]
            switch($fault){
                ambiguous {$binding.Resolved+=($original.PSObject.Copy())}
                alias {$original.CommandType='Alias'}
                proxy {$binding.Resolved=@($original.PSObject.Copy());$binding.Resolved[0].Definition='param() # proxy'}
                foreignModule {$original.Module=$original.Module.PSObject.Copy()}
            }
            {Assert-WslColdStorageCommandBinding @binding}|Should -Throw
        }
    }
    It 'refuses module search names, traversal, unsupported declarations and non-CDXML command owners' {
        $binding=New-StorageOwnershipModel
        foreach($relative in @('../Disk.cdxml','sub/Disk.cdxml','sub\Disk.cdxml','C:\Disk.cdxml','Disk.dll','Disk','')){{Resolve-WslColdStorageNestedPath $binding.ManifestPath $relative}|Should -Throw}
        (Resolve-WslColdStorageNestedPath $binding.ManifestPath 'Disk.cdxml')|Should -BeExactly $binding.NestedPaths[0]
        $binding.Parent.NestedModules[0].Path=Join-Path $TestDrive 'system/Storage/Disk.psm1';$binding.Parent.NestedModules[0].ModuleType='Script';$binding.NestedPaths=@($binding.Parent.NestedModules[0].Path)
        {Assert-WslColdStorageCommandBinding @binding}|Should -Throw
    }
    It 'resolves the real installed Microsoft Storage manifest and CDXML commands without executing disk commands' -Skip:(-not $IsWindows) {
        $first=Get-WslColdStoragePreflight;$second=Get-WslColdStoragePreflight
        $first.commands.Count|Should -Be 7;$first.files.Count|Should -BeGreaterThan 1
        $first.readOnly|Should -BeTrue;$first.diskCommandsExecuted|Should -BeFalse;$first.volumeAccepted|Should -BeFalse;$first.productionAccepted|Should -BeFalse
        (ConvertTo-Json -InputObject $second -Depth 12 -Compress)|Should -BeExactly (ConvertTo-Json -InputObject $first -Depth 12 -Compress)
        foreach($command in $first.commands){[IO.Path]::GetExtension($command.modulePath)|Should -BeExactly '.cdxml'}
    }
}
Describe 'Raw descriptor layout and synthetic-only volume admission' {
    It 'distinguishes compact ACL bytes from declared zero spare and preserves complete raw bytes' {
        foreach($capacity in @(68,72,248,256)){
            $bytes=LayoutBytes $capacity;$l=[Revealfleet.Backup.ColdSecurityLayout]::Inspect($bytes)
            $l.OwnerBytes|Should -Be 28;$l.GroupBytes|Should -Be 28;$l.DaclOffset|Should -Be 76
            $l.ParsedAclBytes|Should -Be 68;$l.AclBytes|Should -Be $capacity;$l.SpareBytes|Should -Be ($capacity-68)
            $l.DescriptorBytes|Should -Be (76+$capacity);$l.RequireWritable()
        }
    }
    It 'bounds generic owner and group lengths without a machine SID exception' {
        foreach($n in @(1,2,5,15)){
            $sid=[byte[]]::new(8+4*$n);$sid[0]=1;$sid[1]=$n;$sid[7]=5
            for($i=0;$i -lt $n;$i++){[BitConverter]::GetBytes([uint32]($i+1)).CopyTo($sid,8+4*$i)}
            $raw=[Revealfleet.Backup.ColdSecurityLayout]::Compose(0x8004,$sid,(SidBytes 513),(AclBytes),248,$null)
            $l=[Revealfleet.Backup.ColdSecurityLayout]::Inspect($raw)
            $l.OwnerBytes|Should -Be (8+4*$n);$l.GroupBytes|Should -Be 28;$l.SpareBytes|Should -Be 180
        }
    }
    It 'rejects overlap, corrupted ACE bounds, nonzero spare and unsupported trailing mutation' {
        $variants=@()
        $x=LayoutBytes;$x[8]=20;$variants+=,@($x)
        $x=LayoutBytes;$x[76+8+2]=252;$variants+=,@($x)
        $x=LayoutBytes;$x[$x.Length-1]=1;$variants+=,@($x)
        foreach($bad in $variants){{[Revealfleet.Backup.ColdSecurityLayout]::Inspect([byte[]]$bad)}|Should -Throw}
        $tail=LayoutBytes 248 ([byte[]](0,0,0,0));$l=[Revealfleet.Backup.ColdSecurityLayout]::Inspect($tail)
        $l.TrailingBytes|Should -Be 4;{$l.RequireWritable()}|Should -Throw
    }
    It 'preserves SID lengths and ACL capacity across owner changes without canonicalizing unused bytes' -Skip:(-not $IsWindows) {
        $original=[Revealfleet.Backup.ColdSecuritySnapshot]::new((LayoutBytes))
        $original.Layout.DescriptorBytes|Should -Be 324
        $admin=$original.WithOwner('S-1-5-32-544');$admin.Layout.OwnerBytes|Should -Be 16;$admin.Layout.AclBytes|Should -Be 248
        $restored=$admin.WithOwner($original.OwnerSid)
        $restored.DescriptorSha256|Should -BeExactly $original.DescriptorSha256
        $target=$original.Restricted('S-1-5-21-111-222-333-1001')
        $target.Layout.AclBytes|Should -Be 248;$target.Layout.ParsedAclBytes|Should -BeGreaterThan 68
    }
    It 'cannot create or attach from existing-image inputs or a fabricated capability' {
        @([Revealfleet.Backup.ColdSyntheticVirtualDisk].GetConstructors()).Count|Should -Be 0
        [Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes|Should -BeLessThan 256MB
        if(-not $IsWindows){{[Revealfleet.Backup.ColdSyntheticVirtualDisk]::CreateNew('/not-a-C-parent',[byte[]]@(),[byte[]]@())}|Should -Throw}
        {Initialize-WslOwnedSyntheticVolume -Owned ([pscustomobject]@{ImagePath='C:\must-not-open.vhd'}) -Evidence $TestDrive}|Should -Throw
    }
    It 'binds every destructive Storage command to verified objects with no numeric or drive-letter selection' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../scripts/lib/WslColdSyntheticVolume.ps1'),[ref]$tokens,[ref]$errors)
        $writes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -and $n.GetCommandName().Split('\')[-1] -cin @('Initialize-Disk','New-Partition','Format-Volume')},$true))
        $writes.Count|Should -Be 3
        foreach($write in $writes){
            $parameters=@($write.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]}|ForEach-Object ParameterName)
            foreach($forbidden in @('Number','DiskNumber','DriveLetter','AssignDriveLetter','Path','UniqueId')){$parameters|Should -Not -Contain $forbidden}
            $parameter=if($write.GetCommandName().Split('\')[-1] -ceq 'Format-Volume'){'Partition'}else{'InputObject'}
            $parameters|Should -Contain $parameter
            $index=0;while($write.CommandElements[$index] -isnot [Management.Automation.Language.CommandParameterAst] -or $write.CommandElements[$index].ParameterName -cne $parameter){$index++}
            $arg=$write.CommandElements[$index+1];$arg|Should -BeOfType ([Management.Automation.Language.VariableExpressionAst])
            $arg.VariablePath.UserPath|Should -BeIn @('disk','part')
        }
    }
    It 'refuses execution without Windows or an independently reviewed plan before any disk command' {
        {Invoke-WslColdSyntheticVolume -PlanPath (Join-Path $TestDrive 'absent-plan.json') -ReviewedPlanSha256 'invalid'}|Should -Throw
        Test-Path -LiteralPath (Join-Path $TestDrive 'fixture.vhd')|Should -BeFalse
    }
}
