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
