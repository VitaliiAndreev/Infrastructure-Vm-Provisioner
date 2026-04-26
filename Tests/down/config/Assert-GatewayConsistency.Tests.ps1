BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\down\config\Assert-GatewayConsistency.ps1"

    function New-TestVm {
        param(
            [string] $VmName  = 'node-01',
            [string] $Gateway = '192.168.1.1'
        )
        [PSCustomObject]@{ vmName = $VmName; gateway = $Gateway }
    }
}

Describe 'Assert-GatewayConsistency' {

    It 'returns the gateway when a single VM is provided' {
        $result = Assert-GatewayConsistency -VmDefs @(New-TestVm)

        $result | Should -Be '192.168.1.1'
    }

    It 'returns the shared gateway when all VMs have the same gateway' {
        $vms = @(
            (New-TestVm -VmName 'node-01' -Gateway '192.168.1.1'),
            (New-TestVm -VmName 'node-02' -Gateway '192.168.1.1')
        )

        $result = Assert-GatewayConsistency -VmDefs $vms

        $result | Should -Be '192.168.1.1'
    }

    It 'throws when two VMs have different gateways' {
        $vms = @(
            (New-TestVm -VmName 'node-01' -Gateway '192.168.1.1'),
            (New-TestVm -VmName 'node-02' -Gateway '10.0.0.1')
        )

        { Assert-GatewayConsistency -VmDefs $vms } |
            Should -Throw -ExpectedMessage '*node-01*node-02*'
    }

    It 'includes both VM names and gateways in the error message' {
        $vms = @(
            (New-TestVm -VmName 'node-01' -Gateway '192.168.1.1'),
            (New-TestVm -VmName 'node-02' -Gateway '10.0.0.1')
        )

        { Assert-GatewayConsistency -VmDefs $vms } |
            Should -Throw -ExpectedMessage '*192.168.1.1*10.0.0.1*'
    }

    It 'throws on the first conflicting VM when three VMs are provided' {
        # The third VM also has a different gateway, but the throw fires on
        # the second VM - the loop exits at the first conflict found.
        $vms = @(
            (New-TestVm -VmName 'node-01' -Gateway '192.168.1.1'),
            (New-TestVm -VmName 'node-02' -Gateway '10.0.0.1'),
            (New-TestVm -VmName 'node-03' -Gateway '172.16.0.1')
        )

        { Assert-GatewayConsistency -VmDefs $vms } |
            Should -Throw -ExpectedMessage '*node-02*'
    }
}
