#################################
# SET CONSTANTS
#################################


param ($name, [string]$option="all")
if ($name -eq $null) {
    $name = read-host -Prompt "Please enter cluster name corresponding to json config file: "
}


$root_working_dir = "C:/Users/Administrator/Desktop/hxlab/"
$iso_working_dir = "C:/Users/Administrator/Desktop/hxlab/isos/"
$vcsa_working_dir = "C:/Users/Administrator/Desktop/hxlab/vcsa_files/"
$ad_templatename = "windows_ad_template"
$vcenter_iso = "VMware-VCSA-all-7.0.1-17327517.iso"

$ErrorActionPreference = "Stop"


#################################
# DECLARE FUNCTIONS
#################################


function Convert-SubnetMaskToMaskLength([string] $subnetmask)
{
  $result = 0; 
  # ensure we have a valid IP address
  [IPAddress] $ip = $subnetmask;
  $octets = $ip.IPAddressToString.Split('.');
  foreach($octet in $octets)
  {
    while(0 -ne $octet) 
    {
      $octet = ($octet -shl 1) -band [byte]::MaxValue
      $result++; 
    }
  }
  return $result.ToString();
}


function Convert-SubnetToGateway([string] $subnet)
{
  $gateway = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"1"
  return $gateway
}

function Convert-SubnetTovCenter([string] $subnet)
{
  $vcenter_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"12"
  return $vcenter_ip
}

function Convert-SubnetToAD_DNS([string] $subnet)
{
  $ad_dns_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"10"
  return $ad_dns_ip
}

function Convert-SubnetToNodeIp([string] $subnet, $node_num)
{
  [string]$last_octet = [int]$node_num+13
  $node_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+$last_octet
  return $node_ip
}





#################################
# CREATE / DECLARE VARIABLES
#################################


$json_input_path = "C:/Users/Administrator/Desktop/hxlab/clusters/"+$name+".json"
$json_input_data = Get-Content -Raw -Path $json_input_path | ConvertFrom-Json

$target_vcenter = $json_input_data.clusterdata.target_vc.target_vcenter_ip
$target_vcenter_username = $json_input_data.clusterdata.target_vc.target_vcenter_username
$target_vcenter_password = $json_input_data.clusterdata.target_vc.target_vcenter_password
$target_vcenter_datastore = $json_input_data.clusterdata.target_vc.target_vcenter_datastore
$target_vcenter_datacenter = $json_input_data.clusterdata.target_vc.target_vcenter_datacenter
$target_vcenter_cluster = $json_input_data.clusterdata.target_vc.target_vcenter_cluster
$target_vcenter_dvs_switch = $json_input_data.clusterdata.target_vc.target_vcenter_dvs_switch
$hx_clustername = $json_input_data.clusterdata.name
$hx_clustersize = $json_input_data.clusterdata.num_of_nodes
$mgmt_subnet = $json_input_data.clusterdata.network.mgmt.subnet
$mgmt_subnetmask = $json_input_data.clusterdata.network.mgmt.mask
$mgmt_vlanid = $json_input_data.clusterdata.network.mgmt.vlanid
$cluster_password = $json_input_data.clusterdata.password
$target_vcenter_resourcepool_path = $target_vcenter_cluster, "Resources", $hx_clustername
$target_vcenter_dvs_portgroup_name = $hx_clustername+"_mgmt_"+$mgmt_subnet
$mgmt_subnet_length = Convert-SubnetMaskToMaskLength($mgmt_subnetmask)
$mgmt_subnet_gateway = Convert-SubnetToGateway($mgmt_subnet)
$ntp_server = $json_input_data.clusterdata.ntp_server
$vcenter_ip = Convert-SubnetTovCenter([string] $mgmt_subnet)
$ad_dns_ip = Convert-SubnetToAD_DNS([string] $mgmt_subnet)
$ad_vmname = $hx_clustername+"_ad_dns"
$domain = $hx_clustername+".hx.local"
$mgmt_subnet_cidr = $mgmt_subnet+"/"+$mgmt_subnet_length



If ($option -eq 'all' -or $option.Contains('1')) {

#################################
# SETUP TARGET VCENTER FOR DEPLOYMENT
#################################


#CONNECT TO TARGET VCENTER SERVER
Write-Host ("`n")
Write-Host ("Connecting to vCenter Server at `"$target_vcenter`".") -ForegroundColor Cyan
$viserver = Connect-VIServer $target_vcenter -user $target_vcenter_username -password $target_vcenter_password
Write-Host ("  --> Done.")

#CREATE RESOURCE POOL IN TARGET VCENTER SERVER
Write-Host ("`n")
Write-Host ("Creating Resource "+$hx_clustername+" in target vCenter Server.") -ForegroundColor Cyan
New-ResourcePool -Location $target_vcenter_cluster -Name $hx_clustername
Write-Host ("  --> Done.")

#CREATE DISTRIBUTED PORTGROUP FOR MGMT NETWORK IN TARGET VCENTER SERVER
Write-Host ("`n")
Write-Host ("Creating Distributed Portgroup for subnet "+$mgmt_subnet+" in target vCenter Server.") -ForegroundColor Cyan
New-VDPortgroup -VDSwitch $target_vcenter_dvs_switch -Name $target_vcenter_dvs_portgroup_name -VlanId $mgmt_vlanid
Write-Host ("  --> Done.")

}


If ($option -eq 'all' -or $option.Contains('2')) {

#################################
# DEPLOY AD / DNS Server
#################################


#CONNECT TO TARGET VCENTER SERVER
Write-Host ("`n")
Write-Host ("Connecting to vCenter Server at `"$target_vcenter`".") -ForegroundColor Cyan
$viserver = Connect-VIServer $target_vcenter -user $target_vcenter_username -password $target_vcenter_password
Write-Host ("  --> Done.")


# CLEAN UP ANY RESIDUAL TEMPORARY CUSTOMIZATION SPECS IN CASE THEY EXIST
if (Get-OSCustomizationSpec $hx_clustername -ErrorAction SilentlyContinue) {
    Remove-OSCustomizationSpec $hx_clustername -Confirm:$false
}


# CREATE NEW TEMPORARY CUSTOMIZATION SPEC BASED ON TEMPLATE CUSTOMIZATION SPEC
Write-Host ("`n")
Write-Host ("Create new temporary vmware customization specification.") -ForegroundColor Cyan
$customspec = Get-OSCustomizationSpec -Name "windows_ad_spec" -Server $viserver | New-OSCustomizationSpec -Name $hx_clustername -Type NonPersistent
Write-Host ("  --> Done.")


# UPDATE NEW TEMPORARY CUSTOMIZATION SPEC WITH STATIC IP ADDRESS INFO
Write-Host ("`n")
Write-Host ("Setting static ip address within temporary vmware customization specification.") -ForegroundColor Cyan
Get-OSCustomizationNicMapping -OSCustomizationSpec $customspec | Set-OSCustomizationNicMapping -IPMode UseStaticIP -IPAddress $ad_dns_ip -SubnetMask $mgmt_subnetmask -DefaultGateway $mgmt_subnet_gateway -Dns "8.8.8.8" | Out-Null
Write-Host ("  --> Done.")


# GET UPDATED TEMPORARY CUSTOMIZATION SPEC
$customspec = Get-OSCustomizationSpec $hx_clustername


# GET SOURCE VM TEMPLATE
Write-Host ("`n")
Write-Host ("Get VM template.") -ForegroundColor Cyan
$template = Get-Template -Name $ad_templatename
Write-Host ("  --> Done.")


# CLONE VM TEMPLATE
Write-Host ("`n")
Write-Host ("Create VM clone from VM template.") -ForegroundColor Cyan
New-VM -Name $ad_vmname -Template $template -ResourcePool $hx_clustername -Datastore $target_vcenter_datastore -OSCustomizationSpec $customspec | Out-Null
Write-Host ("  --> Done.")


# SET PORTGROUP
Get-VM $ad_vmname | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $target_vcenter_dvs_portgroup_name -Confirm:$FALSE | Set-NetworkAdapter -StartConnected $true -Confirm:$FALSE


# POWER-ON VM CLONE
Write-Host ("`n")
Write-Host ("Power-on VM clone.") -ForegroundColor Cyan
Start-VM -VM $ad_vmname | Out-Null
Write-Host ("  --> Done.")


# CHECK VM CUSTOMIZATION STATUS
Write-Host ("`n")
Write-Host ("Verifying customization for VM `"$ad_vmname`" has started.") -ForegroundColor Cyan
	while($True)
	{
		$DCvmEvents = Get-VIEvent -Entity $ad_vmname 
		$DCstartedEvent = $DCvmEvents | Where { $_.GetType().Name -eq "CustomizationStartedEvent" }
 
		if ($DCstartedEvent)
		{
			Write-Host ("  --> Done.")
            break	
		}
 
		else 	
		{
			Start-Sleep -Seconds 5
		}
	}

Write-Host ("`n") 
Write-Host ("Waiting for customization of VM `"$ad_vmname`" to complete.") -ForegroundColor Cyan
Write-Host ("  Note: This may take a few minutes to complete.") -ForegroundColor Green
	while($True)
	{
		$DCvmEvents = Get-VIEvent -Entity $ad_vmname 
		$DCSucceededEvent = $DCvmEvents | Where { $_.GetType().Name -eq "CustomizationSucceeded" }
        $DCFailureEvent = $DCvmEvents | Where { $_.GetType().Name -eq "CustomizationFailed" }
 
		if ($DCFailureEvent)
		{
			Write-Warning -Message "Customization of VM $ad_vmname failed" -Verbose
            return $False	
		}
 
		if ($DCSucceededEvent) 	
		{
            Write-Host ("  --> Done.")
            break
		}
        Start-Sleep -Seconds 5
	}
 

# WAITS TO ENSURE SERVICES COME UP AFTER REBOOT
Write-Host ("`n")
Write-Host ("Waiting for VM `"$ad_vmname`" to complete post-customization reboot.") -ForegroundColor Cyan
Start-Sleep -Seconds 30
Wait-Tools -VM $ad_vmname -TimeoutSeconds 300 | Out-Null
Start-Sleep -Seconds 30
Write-Host ("  --> Done.")


# CLEAN UP TEMPORARY CUSTOMIZATION SPEC
Remove-OSCustomizationSpec $hx_clustername -Confirm:$false -ErrorAction SilentlyContinue


# CREATE CREDENTIAL FOR PSSESSION
$pass = $cluster_password | ConvertTo-SecureString -asPlainText -Force
$username = "administrator"
$credential = New-Object System.Management.Automation.PSCredential($username,$pass)


# CREATE NEW PSSESSION
Write-Host ("`n")
Write-Host ("Creating remote powershell session to VM `"$ad_vmname`".") -ForegroundColor Cyan
$adserver = New-PSSession -Name 'adserver' -ComputerName $ad_dns_ip -Credential $credential
Write-Host ("  --> Done.")


# INSTALL AD-DOMAIN-SERVICES ROLE
Write-Host ("`n")
Write-Host ("Installing active directory role on VM `"$ad_vmname`".") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -Restart} | Out-Null
Write-Host ("  --> Done.")


# IMPORT ADDSDEPLOYMENT MODULE
Write-Host ("`n")
Write-Host ("Importing ADDSDeployment powershell module on VM `"$ad_vmname`".") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {Import-Module ADDSDeployment} | Out-Null
Write-Host ("  --> Done.")


# PROMOTE AD SERVER AND CREATE NEW FOREST
Write-Host ("`n")
Write-Host ("Promoting VM `"$ad_vmname`" and create new active directory forest.") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {param($pass,$domain) Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath “C:\Windows\NTDS” -SafeModeAdministratorPassword $pass -DomainMode “7” -DomainName $domain -ForestMode “Win2012R2” -InstallDns:$true -LogPath “C:\Windows\NTDS” -NoRebootOnCompletion:$false -SysvolPath “C:\Windows\SYSVOL” -Force:$true} -ArgumentList $pass,$domain | Out-Null
Write-Host ("  --> Done.")


# CLOSE PSSESSION
Remove-PSSession -Session $adserver


# WAIT FOR AD PROMO REBOOT
Write-Host ("`n")
Write-Host ("Waiting for VM `"$ad_vmname`" to reboot and apply configuration changes.") -ForegroundColor Cyan
Write-Host ("  Note: This will take several minutes to complete.") -ForegroundColor Green
Start-Sleep -Seconds 480
Write-Host ("  --> Done.")


# CREATE NEW PSSESSION
$adserver = New-PSSession -Name 'adserver' -ComputerName $ad_dns_ip -Credential $credential


# CREATE DNS REVERSE LOOKUP ZONE
Write-Host ("`n")
Write-Host ("Create new DNS reverse lookup zone.") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {param($mgmt_subnet_cidr) Add-DnsServerPrimaryZone -NetworkID $mgmt_subnet_cidr -ReplicationScope "Forest"} -ArgumentList $mgmt_subnet_cidr -WarningAction SilentlyContinue | Out-Null
Write-Host ("  --> Done.")


# ADD DNS RECORDS FOR HX NODES
Write-Host ("`n")
Write-Host ("Create DNS A records and PTR records for HX nodes.")
Write-Host ("hxclustersize: "+$hx_clustersize)
For ($i=1; $i -lt ([int]$hx_clustersize + 1); $i++) {
    $nodename = "hx-node-"+[string]$i
    Write-Host ("  <>Adding records for: "+$nodename)
    $node_num = $i
    $node_ip = Convert-SubnetToNodeIp $mgmt_subnet $node_num
    Invoke-Command -Session $adserver -ScriptBlock {param($nodename,$domain,$node_ip) Add-DnsServerResourceRecordA -Name $nodename -ZoneName $domain -IPv4Address $node_ip -CreatePtr} -ArgumentList $nodename,$domain,$node_ip | Out-Null
    }
Write-Host ("  --> Done.")


# CONFIGURE NTP SERVER
Write-Host ("`n")
Write-Host ("Update NTP server configuration.") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {net stop w32time} | Out-Null
Invoke-Command -Session $adserver -ScriptBlock {param($ntp_server) w32tm /config /syncfromflags:manual /manualpeerlist:”$ntp_server"} -ArgumentList $ntp_server | Out-Null
Invoke-Command -Session $adserver -ScriptBlock {w32tm /config /reliable:yes} | Out-Null
Invoke-Command -Session $adserver -ScriptBlock {net start w32time} | Out-Null
Write-Host ("  --> Done.")

# SET ADMINISTRATOR PASSWORD TO NEVER EXPIRE
Write-Host ("`n")
Write-Host ("Setting Administrator password to never expire")
Invoke-Command -Session $adserver -ScriptBlock {$user = Get-ADUser -Filter 'Name -like "Administrator"' | select -expand ObjectGUID; Set-ADUser -Identity $user -PasswordNeverExpires $true} | Out-Null
Write-Host ("  --> Done.")


# CLOSE PSSESSION
Write-Host ("`n")
Write-Host ("Closing remote powershell session to VM `"$ad_vmname`".") -ForegroundColor Cyan
Remove-PSSession -Session $adserver
Write-Host ("  --> Done.")


#DISCONNECT FROM VCENTER SERVER
Write-Host ("`n")
Write-Host ("Disconnecting from vCenter Server `"$target_vcenter`".") -ForegroundColor Cyan
Disconnect-VIServer -Server $viserver -Confirm:$false
Write-Host ("  --> Done.")


}

If ($option -eq 'all' -or $option.Contains('3')) {

#################################
# DEPLOY VCENTER SERVER FOR CLUSTER
#################################


#MAKE COPY OF "vcsa_json_template" FILE FOR THIS VCENTER DEPLOYMENT
$destination_vcsa_file = $vcsa_working_dir+$hx_clustername+"_vcsa.json"
Copy-Item ($vcsa_working_dir+"vcsa_json_orig.json") -Destination $destination_vcsa_file


#UPDATE COPY OF JSON TEMPLATE WITH DEPLOYMENT SPECIFIC DATA
$pathToJson = $destination_vcsa_file
$vcsa_json = Get-Content $pathToJson | ConvertFrom-Json
$vcsa_json.new_vcsa.vc.hostname = $target_vcenter
$vcsa_json.new_vcsa.vc.username = $target_vcenter_username
$vcsa_json.new_vcsa.vc.password = $target_vcenter_password
$vcsa_json.new_vcsa.vc.deployment_network = $target_vcenter_dvs_portgroup_name
$vcsa_json.new_vcsa.vc.datacenter = @($target_vcenter_datacenter)
$vcsa_json.new_vcsa.vc.datastore = $target_vcenter_datastore
$vcsa_json.new_vcsa.vc.target = @($target_vcenter_cluster,"Resources",$hx_clustername)
$vcsa_json.new_vcsa.appliance.name = $hx_clustername+"_vcenter" 
$vcsa_json.new_vcsa.network.ip = $vcenter_ip
$vcsa_json.new_vcsa.network.dns_servers = @($ad_dns_ip)
$vcsa_json.new_vcsa.network.prefix = $mgmt_subnet_length
$vcsa_json.new_vcsa.network.gateway = $mgmt_subnet_gateway
$vcsa_json.new_vcsa.network.system_name = $vcenter_ip
$vcsa_json.new_vcsa.os.password = $cluster_password
$vcsa_json.new_vcsa.os.ntp_servers = $ntp_server
$vcsa_json.new_vcsa.sso.password = $cluster_password

$vcsa_json | ConvertTo-Json -Depth 4 | Out-File -FilePath $pathToJson -Encoding Ascii -Force

#MOUNT VCSA ISO IMAGE ON LOCAL MACHINE
$mountResult = Mount-DiskImage -ImagePath ($iso_working_dir + $vcenter_iso) -PassThru
$driveLetter = ($mountResult | Get-Volume).DriveLetter
Write-Host ("ISO drive letter: " + $driveLetter)

#Get JSON config file full path
Write-Host ("JSON config file path: " + $destination_vcsa_file)

#Execute VCSA installation
$command = $driveLetter + ":\vcsa-cli-installer\win32\vcsa-deploy.exe install --accept-eula --acknowledge-ceip --verbose --no-ssl-certificate-verification " + $destination_vcsa_file
Write-Host ("Command: " + $command)
Invoke-Expression $command

}