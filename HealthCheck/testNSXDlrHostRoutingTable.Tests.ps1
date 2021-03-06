﻿<#
Copyright © 2017 VMware, Inc. All Rights Reserved. 
SPDX-License-Identifier: MIT

#VMware NSX Healthcheck test
#NSX Manager tests
#Askar Kopbayev
#vmnomad

NSX Power Operations

Copyright 2017 VMware, Inc.  All rights reserved				

The MIT license (the ìLicenseî) set forth below applies to all parts of the NSX Power Operations project.  You may not use this file except in compliance with the License.†

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), 
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, 
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#>

#region Functions
 
 function invoke-NSXCLICmd($commandToInvoke, $session){
    write-progress -activity "Executing NSX CLI Command: $commandToInvoke"
    $xmlBody = "<nsxcli>
     <command> $commandToInvoke </command>
     </nsxcli>"
    $AdditionalHeaders = @{"Accept"="text/plain"; "Content-type"="Application/xml"}
    $nsxCLIResponceweb = Invoke-NsxWebRequest -URI "/api/1.0/nsx/cli?action=execute" -method post -extraheader $AdditionalHeaders -body $xmlBody -connection $session
    write-progress -activity "Executing NSX CLI Command: $commandToInvoke" -Completed
    
    return $nsxCLIResponceweb
}

 #http://jongurgul.com/blog/get-stringhash-get-filehash/ 
Function Get-StringHash([String] $String,$HashName = "MD5") { 
    $StringBuilder = New-Object System.Text.StringBuilder 
    [System.Security.Cryptography.HashAlgorithm]::Create($HashName).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($String))|%{ 
        [Void]$StringBuilder.Append($_.ToString("x2")) 
    } 
    $StringBuilder.ToString() 
}

function ConvertTo-Mask {
  <#
    .Synopsis
      Returns a dotted decimal subnet mask from a mask length.
    .Description
      ConvertTo-Mask returns a subnet mask in dotted decimal format from an integer value ranging 
      between 0 and 32. ConvertTo-Mask first creates a binary string from the length, converts 
      that to an unsigned 32-bit integer then calls ConvertTo-DottedDecimalIP to complete the operation.
    .Parameter MaskLength
      The number of bits which must be masked.
  #>
  
  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [Alias("Length")]
    [ValidateRange(0, 32)]
    $MaskLength
  )
  
  Process {
    return ConvertTo-DottedDecimalIP ([Convert]::ToUInt32($(("1" * $MaskLength).PadRight(32, "0")), 2))
  }
}

function ConvertTo-DottedDecimalIP {
  <#
    .Synopsis
      Returns a dotted decimal IP address from either an unsigned 32-bit integer or a dotted binary string.
    .Description
      ConvertTo-DottedDecimalIP uses a regular expression match on the input string to convert to an IP address.
    .Parameter IPAddress
      A string representation of an IP address from either UInt32 or dotted binary.
  #>

  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [String]$IPAddress
  )
  
  process {
    Switch -RegEx ($IPAddress) {
      "([01]{8}.){3}[01]{8}" {
        return [String]::Join('.', $( $IPAddress.Split('.') | ForEach-Object { [Convert]::ToUInt32($_, 2) } ))
      }
      "\d" {
        $IPAddress = [UInt32]$IPAddress
        $DottedIP = $( For ($i = 3; $i -gt -1; $i--) {
          $Remainder = $IPAddress % [Math]::Pow(256, $i)
          ($IPAddress - $Remainder) / [Math]::Pow(256, $i)
          $IPAddress = $Remainder
         } )
       
        return [String]::Join('.', $DottedIP)
      }
      default {
        Write-Error "Cannot convert this format"
      }
    }
  }

}

function get-HostRoutingTable{
    param(
    $vdrID,
    $hostID,
    $connection
    )
    
    # get CLI output
    $result = (invoke-NSXCLICmd -commandToInvoke "show logical-router host $hostID dlr $vdrID route" -session $connection).content
    
    # process string output to create array for a host routing table
    $routingTableMatches = Select-String "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([^\[][UGCIHF\!E]{1,3})\s+(\d)\s+(MANUAL|AUTO)" -Input $result -AllMatches -CaseSensitive | Foreach {$_.matches}
    $routingTableArray = @()
    for($i= 0; $i -lt $routingTableMatches.count; $i++){
        $a = New-Object -TypeName PSObject 
        $a | Add-Member -MemberType NoteProperty -Name Destination -Value $routingTableMatches[$i].groups[1].value
        $a | Add-Member -MemberType NoteProperty -Name Netmask -Value $routingTableMatches[$i].groups[2].value
        $a | Add-Member -MemberType NoteProperty -Name Gateway -Value $routingTableMatches[$i].groups[3].value
        $a | Add-Member -MemberType NoteProperty -Name Flags -Value $routingTableMatches[$i].groups[4].value
        $a | Add-Member -MemberType NoteProperty -Name String  -Value $($a.Destination + $a.Netmask)
        $a | Add-Member -MemberType NoteProperty -Name Hash  -Value $(get-stringHash $a.string "MD5")
        $routingTableArray += $a
    }
   
    
    return $routingTableArray
}

function get-DLRRoutingTable{
    param(
    $NsxManager,
    $edgeID,
    $connection,
    $HAstatus
    )
    
    # get CLI output
    $result = (invoke-NSXCLICmd -commandToInvoke "show edge $edgeID ip route" -session $connection).content
    
    # process string output to create array for a DLR routing table
    $routingTableMatches = Select-String "([OiBCS]|L1|L2|IA|E1|E2|N1|N2)\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2}).*via\s{1}(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})" -Input $result -AllMatches -CaseSensitive | Foreach {$_.matches}
    $routingTableArray = @()
    $dlrSummary = @()
    for($i= 0; $i -lt $routingTableMatches.count; $i++){
        $a = New-Object -TypeName PSObject 
        $a | Add-Member -MemberType NoteProperty -Name Flag -Value $routingTableMatches[$i].Groups[1].value
        $a | Add-Member -MemberType NoteProperty -Name Destination -Value $routingTableMatches[$i].Groups[2].value
        $a | Add-Member -MemberType NoteProperty -Name Netmask -Value $(ConvertTo-Mask -MaskLength $($routingTableMatches[$i].Groups[3].value))
        $a | Add-Member -MemberType NoteProperty -Name Gateway -Value $routingTableMatches[$i].Groups[4].value
        $a | Add-Member -MemberType NoteProperty -Name String  -Value $($a.Destination + $a.Netmask)
        $a | Add-Member -MemberType NoteProperty -Name Hash -Value $(get-stringHash $a.string "MD5")
        # Ignore Connected Routes on HA Enabled DLRs
        if(($HAstatus -eq "True") -and ($a.Hash -ne "81a42c4978a79ec7d4d98ff515bbd411")){
            $routingTableArray += $a
        }
    }
    $b = New-Object -TypeName PSObject 
    $b |  Add-Member -MemberType NoteProperty -Name EdgeID -Value $edgeID
    $b |  Add-Member -MemberType NoteProperty -Name CommonHash -Value $(get-stringHash $routingTableArray.string "MD5")
    $b | Add-Member -MemberType NoteProperty -Name RoutingTable -value $routingTableArray 
    $dlrSummary += $b
    return $dlrSummary
}

function get-vdrID{
    param(
    $edgeID,
    $connection
    )
    
    # get SSH output
    $result = (invoke-NSXCLICmd -commandToInvoke "show logical-router host $($vSphereHosts[0].id) dlr all brief" -session $connection).content
    
    # process string output to find VDR ID
    $vdrIdMatches = Select-String "(edge-\d{1,3})\s*(0x[a-f0-9]+)" -Input $result -AllMatches  | Foreach {$_.matches}
    for($i = 0; $i -lt $vdrIdMatches.Count; $i++){     
        if($vdrIdMatches[$i].groups[1].value -match $edgeID){
            $vdrID = $vdrIdMatches[$i].groups[2].value
        }
    }
    return $vdrID
}

function Show-Menu{
     param (
           [string]$Title = 'My Menu'
     )
     cls
     Write-Host "============= $Title ============="
     
     for($i =1 ; $i -le $dlrs.Count; $i++){
         Write-Host "$($i): $($dlrs[$i-1].name)"
    }
}

#endregion

# NSX Server connection and credentials
$server = $NSXConnection.server
$nsxAdminConnection = Connect-NsxServer -NsxServer $NSXConnection.server -Credential $NSXManagerCredential -DefaultConnection:$false -DisableVIAutoConnect:$true -WarningAction SilentlyContinue

# Get all Logical Routers
$dlrs = Get-NsxLogicalRouter -Connection $NSXConnection

# dynamic menu based on number of DLRs
if(!$dlrs){
    Write-Error "No DLRs were found" -ErrorAction Stop
}
elseif(($dlrs | measure).count -eq 1){
    Write-Host "Found single logical router $($dlrs.name)"
    $dlrname = $dlrs.Name
    $tzID = $dlrs.edgeSummary.logicalRouterScopes.logicalRouterScope.id
}  
else{  
    do{
        Show-Menu 'Discovered Logical Routers'
        $choice = Read-Host -Prompt "`nSelect DLR to validate"

    } while(($choice -lt 1) -or ($choice -gt $dlrs.Count))
    $dlrname = $dlrs[$choice-1].name
    $tzID = ($dlrs[$choice-1].edgeSummary.logicalRouterScopes.logicalRouterScope | ?{$_.Type -eq "TransportZone"}).id
}

# get clusters in the same transport zone where DLR resides
$clusters =  (Get-NsxTransportZone -Connection $NSXConnection | ?{$_.id -eq $tzid}).clusters.cluster.cluster.name | %{get-cluster $_ -Server $NSXConnection.ViConnection}

# collect hosts from NSX prepared clusters only 
$vSphereHosts = @()
$clusters | %{
    if((Get-NsxClusterStatus $_ -Connection $NSXConnection| ?{$_.featureid -eq "com.vmware.vshield.vsm.nwfabric.hostPrep"}).installed -eq "true"){
        $vSphereHosts += $_ | Get-VMHost -Server $NSXConnection.ViConnection | select Name,ID
    }
}

if(!$vSphereHosts){
    Write-Error "No hosts were detected" -ErrorAction stop 
}
else{
    $vSphereHosts | %{$_.id = $_.id.split("-",2)[1]}
}

# collecting VDR ID
Write-Host "`nCollecting routing table from $dlrName " 
$edgeID = Get-NsxLogicalRouter -Name $dlrName -Connection $NSXConnection

$EdgeHAstatus = $edgeID.features.highAvailability.enabled
$vdrID = get-vdrID -connection $nsxAdminConnection -edgeID $edgeID.id

# Collect DLR Routing Table
$dlrRoutingTable = get-DLRRoutingTable -connection $nsxAdminConnection -edgeID $edgeiD.id -HAstatus $EdgeHAstatus

# Collect routing tables from all ESXi servers
$vSphereHostsRoutingTable=@()
foreach($vmhost in $vSphereHosts){
    Write-host "Collecting routing table from host $($vmhost.name)"
    $hostRoutingTable = get-hostRoutingTable -connection $nsxAdminConnection -vdrID $vdrID -hostID $vmhost.id
    $a = New-Object -TypeName PSobject
    $a | Add-Member -MemberType NoteProperty -Name hostname -Value $vmhost.name
    $a | Add-Member -MemberType NoteProperty -Name routingTable -Value $hostRoutingTable
    $a | Add-Member -MemberType NoteProperty -Name CommonHash -Value $(get-stringHash $hostRoutingTable.string "MD5")
    $vSphereHostsRoutingTable += $a
}


# Compare Routes
$faultyHosts = @()
foreach($vmhost in $vSphereHostsRoutingTable){
    Write-host -Fore:Magenta "`nValidating routing table of ESXi server $($vmhost.hostname)"
    $faultyRoutes = $true    

    # compare the routing tables of DLR and ESXi host
    it "EsXi server routing table matches DLR routing table" {$dlrRoutingTable.CommonHash -eq $vmhost.CommonHash | Should Be $true}
  
    # Collect the list of hosts with faulty routing tables
    if($dlrRoutingTable.CommonHash -eq $vmhost.CommonHash){
        $faultyRoutes = $false
    }

    if($faultyRoutes){
        $faultyHosts += $vmhost.hostname
    }
}



# get current path
$path = $documentlocation

# Create and export summary report
$report = @()
$report += "DLR Name: $dlrname"
$report += "Transport Zone: $((Get-NsxTransportZone -Connection $NSXConnection | ?{$_.id -eq $tzid}).name)"
$report += " "
$report += "All Hosts in Transport Zone:"
foreach($server in $vSphereHosts){
    $report += "`t`t $($server.name)"
}
$report += " "
$report += "Hosts with inconsistent routing table:"
foreach($server in $faultyHosts){
    $report += "`t`t $($server)"
}

$timeStamp = Get-Date -Format "yyyy-MM-dd_hh-mm"

write-host -fore:yellow "`nExporting summary report to $($path+"\DLR_Validation_Summary_Report-" + $timeStamp +".txt")"
$report | Out-File $($path+"\DLR_Validation_Summary_Report-" + $timeStamp + ".txt")


# Create and export routing table report
$RoutingTablereport = @()
$RoutingTablereport += "DLR Name: $dlrname"
$RoutingTablereport += "`t `t $($dlrRoutingTable.RoutingTable | select Destination,Netmask,Gateway,Flag | Out-String)"
foreach($server in $vSphereHostsRoutingTable){
    $RoutingTablereport += "Hostname: $($server.hostname)"
    $RoutingTablereport += "`t`t $($server.routingTable | select Destination,Netmask,Gateway,Flags | Out-String)"
}


write-host -fore:yellow "`nExporting DLR and ESXi routing tables to $($path+"\DLR_Validation_Routing_Table_Report-"+ $timeStamp +".txt")"
$RoutingTablereport | Out-File $($path+"\DLR_Validation_Routing_Table_Report-" + $timeStamp + ".txt")

