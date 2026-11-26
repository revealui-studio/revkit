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
    function New-StorageUInt16Model {
        return @{SystemProperties=[pscustomobject]@{ClassName='MSFT_Disk';Namespace='root/Microsoft/Windows/Storage';ServerName=$null};Properties=@([pscustomobject]@{Name='BusType';CimType=[Microsoft.Management.Infrastructure.CimType]::UInt16;Value=[uint16]15});ClassName='MSFT_Disk';PropertyName='BusType'}
    }
    function New-PartitionObservationModel {
        $disk=@{Path='owned-synthetic-device';UniqueId='synthetic-native-id';Number=[uint32]3;Size=[uint64]128MB;LogicalSectorSize=[uint32]512;IsBoot=$false;IsSystem=$false}
        $part=@{ObjectId='synthetic-partition-id';DiskNumber=[uint32]3;Offset=[uint64]1MB;Size=[uint64]126MB}
        return @{disk=$disk;returned=$part;parents=@($disk.Clone());current=@($part.Clone())}
    }
}
Describe 'Permission ACE candidate and independent raw identity' {
    It 'distinguishes zero unused ACL capacity from raw forensic equality without rewriting inputs' {
        $padded=LayoutBytes;$compact=LayoutBytes 68;$retained=[Convert]::ToBase64String($padded)
        $delta=[Revealfleet.Backup.ColdPermissionIdentity]::Compare($padded,$compact)
        $delta.Profile|Should -BeExactly 'permission-ace-zero-unused-v1'
        $delta.Classification|Should -BeExactly 'ValidatedZeroUnusedAclCapacityOnly'
        $delta.RawEqual|Should -BeFalse;$delta.RawByteRestorationPromised|Should -BeFalse
        $delta.RequestedAclBytes|Should -Be 248;$delta.ObservedAclBytes|Should -Be 68;$delta.AclBytesInUse|Should -Be 68
        $delta.RequestedRawSha256|Should -Not -Be $delta.ObservedRawSha256
        [Convert]::ToBase64String($padded)|Should -BeExactly $retained
        ([Revealfleet.Backup.ColdPermissionIdentity]::Compare($padded,$padded)).Classification|Should -BeExactly 'ExactRaw'
        ([Revealfleet.Backup.ColdPermissionIdentity]::new($padded)).UsedIdentitySha256|Should -BeExactly ([Revealfleet.Backup.ColdPermissionIdentity]::new($compact)).UsedIdentitySha256
    }
    It 'rejects every changed meaningful byte rather than accepting broad access equivalence' {
        $base=LayoutBytes 68;$dacl=[BitConverter]::ToInt32($base,16)
        # AclSize alone describes validated free allocation. Every other byte
        # belongs to the exact header, SID, ACL header or ordered ACE payload.
        $tested=0
        for($i=0;$i -lt $base.Length;$i++){
            if($i -in @(($dacl+2),($dacl+3))){continue}
            $changed=[byte[]]$base.Clone();$changed[$i]=$changed[$i] -bxor 1
            {[Revealfleet.Backup.ColdPermissionIdentity]::Compare($base,$changed)}|Should -Throw -Because ('meaningful byte '+$i+' must remain exact')
            $tested++
        }
        $tested|Should -Be ($base.Length-2)
    }
    It 'preserves supported control bits, revision and ordered ACEs exactly' {
        $base=LayoutBytes 68
        foreach($control in @(0x8006,0x8404,0x9004)){
            $changed=[byte[]]$base.Clone();[BitConverter]::GetBytes([uint16]$control).CopyTo($changed,2)
            {[Revealfleet.Backup.ColdPermissionIdentity]::new($changed)}|Should -Not -Throw
            {[Revealfleet.Backup.ColdPermissionIdentity]::Compare($base,$changed)}|Should -Throw
        }
        $d=[BitConverter]::ToInt32($base,16);$changed=[byte[]]$base.Clone();$changed[$d]=4
        {[Revealfleet.Backup.ColdPermissionIdentity]::new($changed)}|Should -Not -Throw
        {[Revealfleet.Backup.ColdPermissionIdentity]::Compare($base,$changed)}|Should -Throw
        $changed=[byte[]]$base.Clone();[Array]::Copy($base,$d+28,$changed,$d+8,20);[Array]::Copy($base,$d+8,$changed,$d+28,20)
        {[Revealfleet.Backup.ColdPermissionIdentity]::Compare($base,$changed)}|Should -Throw
    }
    It 'refuses unsupported SACL, object, callback, conditional, opaque, null and empty forms' {
        $base=LayoutBytes;$d=[BitConverter]::ToInt32($base,16)
        foreach($fault in @('sacl','sacl-control','object','callback','deny','no-propagate','audit-flag','generic-rights','empty','null','opaque')){
            $changed=[byte[]]$base.Clone()
            switch($fault){
                sacl {[BitConverter]::GetBytes([uint32]20).CopyTo($changed,12)}
                sacl-control {[BitConverter]::GetBytes([uint16]0x8014).CopyTo($changed,2)}
                object {$changed[$d+8]=5}
                callback {$changed[$d+8]=9}
                deny {$changed[$d+8]=1}
                no-propagate {$changed[$d+9]=7}
                audit-flag {$changed[$d+9]=67}
                generic-rights {$changed[$d+15]=128}
                empty {$changed[$d+4]=0}
                null {[BitConverter]::GetBytes([uint32]0).CopyTo($changed,16)}
                opaque {[BitConverter]::GetBytes([uint16]24).CopyTo($changed,$d+10)}
            }
            {[Revealfleet.Backup.ColdPermissionIdentity]::new($changed)}|Should -Throw -Because $fault
        }
    }
    It 'rejects nonzero spare, hidden ACE, outer trailing allocation, bad bounds and reserved bytes' {
        $base=LayoutBytes;$d=[BitConverter]::ToInt32($base,16)
        foreach($fault in @('nonzero-spare','hidden-ace','short-acl','unaligned-acl','overflow-acl','acl-reserved1','acl-reserved2','header-reserved','sid-gap','sid-overlap','sid-overflow','ace-overflow','count-overflow')){
            $changed=[byte[]]$base.Clone()
            switch($fault){
                nonzero-spare {$changed[-1]=1}
                hidden-ace {$changed[$d+68]=0;$changed[$d+69]=3;$changed[$d+70]=20}
                short-acl {$changed[$d+2]=64}
                unaligned-acl {$changed[$d+2]=247}
                overflow-acl {[BitConverter]::GetBytes([uint16]65532).CopyTo($changed,$d+2)}
                acl-reserved1 {$changed[$d+1]=1}
                acl-reserved2 {$changed[$d+6]=1}
                header-reserved {$changed[1]=1}
                sid-gap {$changed[8]=49}
                sid-overlap {$changed[8]=20}
                sid-overflow {$changed[21]=15}
                ace-overflow {[BitConverter]::GetBytes([uint16]252).CopyTo($changed,$d+10)}
                count-overflow {[BitConverter]::GetBytes([uint16]65535).CopyTo($changed,$d+4)}
            }
            {[Revealfleet.Backup.ColdPermissionIdentity]::new($changed)}|Should -Throw -Because $fault
        }
        foreach($tail in @([byte[]](0,0,0,0),[byte[]](0,0,0,1))){
            {[Revealfleet.Backup.ColdPermissionIdentity]::new((LayoutBytes 248 $tail))}|Should -Throw
        }
    }
    It 'uses the entire actual raw descriptor for CAS even when permission identity matches' {
        $padded=LayoutBytes;$compact=LayoutBytes 68
        $a=[Revealfleet.Backup.ColdPermissionIdentity]::new($padded);$b=[Revealfleet.Backup.ColdPermissionIdentity]::new($compact)
        {[Revealfleet.Backup.ColdPermissionIdentity]::RequireRawCas($compact,$b.RawSha256)}|Should -Not -Throw
        {[Revealfleet.Backup.ColdPermissionIdentity]::RequireRawCas($compact,$a.RawSha256)}|Should -Throw '*raw CAS drift*'
        {[Revealfleet.Backup.ColdPermissionIdentity]::RequireRawCas($compact,$b.UsedIdentitySha256)}|Should -Throw '*raw CAS drift*'
        # Forensic bytes may be recorded before synthetic seed even when their
        # wider grammar would be refused for a candidate replacement target.
        $wider=[byte[]]$compact.Clone();$wider[1]=1
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($wider)).ToLowerInvariant()
        {[Revealfleet.Backup.ColdPermissionIdentity]::RequireRawCas($wider,$hash)}|Should -Not -Throw
        {[Revealfleet.Backup.ColdPermissionIdentity]::new($wider)}|Should -Throw
    }
}
Describe 'Reviewed partition layout and format boundary' {
    It 'requests one MiB offset and alignment and refuses the observed default before modeled format' {
        $layout=Get-WslColdSyntheticPartitionLayout
        $layout.offsetBytes|Should -BeOfType ([uint64]);$layout.offsetBytes|Should -Be 1MB
        $layout.alignmentBytes|Should -BeOfType ([uint32]);$layout.alignmentBytes|Should -Be 1MB
        $script:modeledFormats=0;$model=New-PartitionObservationModel
        & {Assert-WslColdSyntheticPartitionObservation $model $layout ([Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes);$script:modeledFormats++}
        $script:modeledFormats|Should -Be 1
        $script:modeledFormats=0;$model.returned.Offset=[uint64]65536;$model.current[0].Offset=[uint64]65536
        {& {Assert-WslColdSyntheticPartitionObservation $model $layout ([Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes);$script:modeledFormats++}}|Should -Throw '*minimum-offset*'
        $script:modeledFormats|Should -Be 0
    }
    It 'distinguishes remaining association mismatches instead of attributing every predicate to offset' {
        foreach($fault in @('current-count','current-object-id','current-layout-drift','parent-count','parent-path','parent-unique-id','disk-number')){
            $model=New-PartitionObservationModel
            switch($fault){
                current-count {$model.current=@()}
                current-object-id {$model.current[0].ObjectId='changed'}
                current-layout-drift {$model.current[0].Size=[uint64]125MB}
                parent-count {$model.parents+=@($model.parents[0].Clone())}
                parent-path {$model.parents[0].Path='different-device'}
                parent-unique-id {$model.parents[0].UniqueId='different-id'}
                disk-number {$model.returned.DiskNumber=[uint32]4}
            }
            {Assert-WslColdSyntheticPartitionObservation $model (Get-WslColdSyntheticPartitionLayout) ([Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes)}|Should -Throw ('*'+$fault+'*')
        }
    }
    It 'refuses changed requested layout and finite extent or sector errors without integer wraparound' {
        foreach($fault in @('offset-size-types','requested-offset','zero-size','overflow-size','sector-alignment')){
            $model=New-PartitionObservationModel
            switch($fault){
                offset-size-types {$model.returned.Offset='1048576'}
                requested-offset {$model.returned.Offset=[uint64]2MB}
                zero-size {$model.returned.Size=[uint64]0}
                overflow-size {$model.returned.Size=[uint64]::MaxValue}
                sector-alignment {$model.disk.LogicalSectorSize=[uint32]768}
            }
            $model.current[0].Offset=$model.returned.Offset;$model.current[0].Size=$model.returned.Size
            {Assert-WslColdSyntheticPartitionObservation $model (Get-WslColdSyntheticPartitionLayout) ([Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes)}|Should -Throw
        }
        $changed=Get-WslColdSyntheticPartitionLayout;$changed.offsetBytes=[uint64]65536
        {Assert-WslColdSyntheticPartitionLayout $changed}|Should -Throw '*reviewed-layout-contract*'
    }
    It 'binds explicit creation arguments and validation immediately before the real format command in source' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../scripts/lib/WslColdSyntheticVolume.ps1'),[ref]$tokens,[ref]$errors)
        $body=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Initialize-WslOwnedSyntheticVolume'},$true).Body
        $calls=@($body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
        $create=@($calls|Where-Object {$_.GetCommandName() -ceq 'Storage\New-Partition'})[0]
        foreach($pair in @(@('Offset','offsetBytes'),@('Alignment','alignmentBytes'))){
            $index=0;while($create.CommandElements[$index] -isnot [Management.Automation.Language.CommandParameterAst] -or $create.CommandElements[$index].ParameterName -cne $pair[0]){$index++;if($index -ge $create.CommandElements.Count){throw 'Missing explicit creation contract'}}
            $arg=$create.CommandElements[$index+1];$arg|Should -BeOfType ([Management.Automation.Language.MemberExpressionAst]);$arg.Expression.VariablePath.UserPath|Should -BeExactly 'Layout';$arg.Member.Value|Should -BeExactly $pair[1]
        }
        $format=@($calls|Where-Object {$_.GetCommandName() -ceq 'Storage\Format-Volume'})[0]
        $previous=@($calls|Where-Object {$_.Extent.EndOffset -lt $format.Extent.StartOffset}|Sort-Object {$_.Extent.EndOffset})[-1]
        $previous.GetCommandName()|Should -BeExactly 'Assert-WslOwnedSyntheticPartition'
        $previous.CommandElements[-1].Value|Should -BeExactly 'pre-format'
        $gate=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-WslOwnedSyntheticPartition'},$true)
        @($gate.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Assert-WslColdSyntheticPartitionObservation'},$true)).Count|Should -Be 1
    }
    It 'verifies real readonly Storage parameter types and client-only partition projection without any disk operation' -Skip:(-not $IsWindows) {
        [void](Get-WslColdStoragePreflight)
        $command=Microsoft.PowerShell.Core\Get-Command Storage\New-Partition -ErrorAction Stop
        $sets=@($command.ParameterSets|Where-Object {('InputObject' -cin $_.Parameters.Name) -and ('Offset' -cin $_.Parameters.Name) -and ('Alignment' -cin $_.Parameters.Name) -and ('UseMaximumSize' -cin $_.Parameters.Name)})
        $sets.Count|Should -BeGreaterThan 0
        @($sets[0].Parameters|Where-Object Name -CEQ Offset)[0].ParameterType|Should -Be ([uint64])
        @($sets[0].Parameters|Where-Object Name -CEQ Alignment)[0].ParameterType|Should -Be ([uint32])
        $partition=CimCmdlets\New-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Partition -Property @{ObjectId='synthetic-partition-id';DiskNumber=[uint32]3;Offset=[uint64]1MB;Size=[uint64]126MB} -ClientOnly
        $model=New-PartitionObservationModel;$model.returned=Get-WslColdSyntheticStorageSnapshot $partition;$model.current=@($model.returned)
        {Assert-WslColdSyntheticPartitionObservation $model (Get-WslColdSyntheticPartitionLayout) ([Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes)}|Should -Not -Throw
    }
}
Describe 'Typed local Storage CIM enum classification' {
    It 'reads exact raw UInt16 observations without consulting adapted display labels' {
        foreach($value in @([uint16]14,[uint16]15)){
            $model=New-StorageUInt16Model;$model.Properties[0].Value=$value
            $raw=Assert-WslColdStorageUInt16Observation @model
            $raw|Should -BeOfType ([uint16]);$raw|Should -Be $value
            {Assert-WslColdSyntheticBusValue $raw}|Should -Not -Throw
        }
        foreach($local in @('','.','localhost',[Environment]::MachineName)){
            $model=New-StorageUInt16Model;$model.SystemProperties.ServerName=$local;$model.SystemProperties.Namespace='Root\Microsoft\Windows\Storage'
            (Assert-WslColdStorageUInt16Observation @model)|Should -Be 15
        }
        {Get-WslColdStorageUInt16 ([pscustomobject]@{BusType='File Backed Virtual'}) 'MSFT_Disk' 'BusType'}|Should -Throw
    }
    It 'refuses wrong class, namespace, remote identity and malformed identity types' {
        foreach($fault in @('class','namespace','remote','serverType','namespaceType')){
            $model=New-StorageUInt16Model
            switch($fault){
                class {$model.SystemProperties.ClassName='MSFT_Volume'}
                namespace {$model.SystemProperties.Namespace='root/cimv2'}
                remote {$model.SystemProperties.ServerName='not-the-local-host.invalid'}
                serverType {$model.SystemProperties.ServerName=42}
                namespaceType {$model.SystemProperties.Namespace=42}
            }
            {Assert-WslColdStorageUInt16Observation @model}|Should -Throw
        }
    }
    It 'refuses absent or duplicate properties, CIM type spoofing and coerced values' {
        foreach($fault in @('missing','duplicate','wrongCimType','stringCimType','intValue','stringValue','nullValue')){
            $model=New-StorageUInt16Model
            switch($fault){
                missing {$model.Properties=@()}
                duplicate {$model.Properties+=@($model.Properties[0])}
                wrongCimType {$model.Properties[0].CimType=[Microsoft.Management.Infrastructure.CimType]::UInt32}
                stringCimType {$model.Properties[0].CimType='UInt16'}
                intValue {$model.Properties[0].Value=[int]15}
                stringValue {$model.Properties[0].Value='15'}
                nullValue {$model.Properties[0].Value=$null}
            }
            {Assert-WslColdStorageUInt16Observation @model}|Should -Throw
        }
    }
    It 'refuses physical and unknown buses even if a display string could claim virtual ownership' {
        foreach($value in @([uint16]0,[uint16]1,[uint16]7,[uint16]16,[uint16]17,15,'15','File Backed Virtual',$null)){{Assert-WslColdSyntheticBusValue $value}|Should -Throw}
    }
    It 'classifies real client-only Microsoft CIM disks through the loaded Storage adapter without provider enumeration' -Skip:(-not $IsWindows) {
        [void](Get-WslColdStoragePreflight)
        foreach($value in @([uint16]14,[uint16]15,[uint16]7)){
            $disk=CimCmdlets\New-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Disk -Property @{BusType=$value} -ClientOnly
            $disk.BusType|Should -BeOfType ([string])
            $raw=Get-WslColdStorageUInt16 $disk 'MSFT_Disk' 'BusType'
            $raw|Should -BeOfType ([uint16]);$raw|Should -Be $value
            if($value -eq 7){{Assert-WslColdSyntheticBusValue $raw}|Should -Throw}else{{Assert-WslColdSyntheticBusValue $raw}|Should -Not -Throw}
        }
        $wrong=CimCmdlets\New-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Disk -Property @{BusType=[uint32]15} -ClientOnly
        {Get-WslColdStorageUInt16 $wrong 'MSFT_Disk' 'BusType'}|Should -Throw
    }
    It 'reads real client-only partition and filesystem enum values without adapted display comparisons' -Skip:(-not $IsWindows) {
        [void](Get-WslColdStoragePreflight)
        foreach($value in @([uint16]0,[uint16]1,[uint16]2)){
            $disk=CimCmdlets\New-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Disk -Property @{PartitionStyle=$value} -ClientOnly
            (Get-WslColdStorageUInt16 $disk 'MSFT_Disk' 'PartitionStyle')|Should -Be $value
        }
        $volume=CimCmdlets\New-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Volume -Property @{FileSystemType=[uint16]14} -ClientOnly
        (Get-WslColdStorageUInt16 $volume 'MSFT_Volume' 'FileSystemType')|Should -Be 14
        {Get-WslColdStorageUInt16 $volume 'MSFT_Disk' 'FileSystemType'}|Should -Throw
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
