


#################################
# SET CONSTANTS
#################################


param ($json_input, $jumphost_name, $ip)
if ($json_input -eq $null) {
    $json_input = read-host -Prompt "Please enter the cluster json file: "
}
if ($jumphost_name -eq $null) {
    $jumphost_name = read-host -Prompt: "Please enter the name for the jumphost: "
}
if ($ip -eq $null) {
    $ip = read-host -Prompt "Please enter a valid IP address for the jumphost: "
}


$root_working_dir = "C:/Users/Administrator/Desktop/hxlab/"
$jumphost_template_name = "windows_jumphost_template"
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
  if ($subnet -eq "10.1.10.0") {
    $ad_dns_ip = [ipaddress]("10.1.10.13")
    return $ad_dns_ip
  } else {
    $ad_dns_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"10"
    return $ad_dns_ip
  }
}


#################################
# CREATE / DECLARE VARIABLES
#################################


$json_input_path = Resolve-Path -Path $json_input
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




#################################
# DEPLOY JUMPSERVER
#################################


#CONNECT TO TARGET VCENTER SERVER
Write-Host ("`n")
Write-Host ("Connecting to vCenter Server at `"$target_vcenter`".") -ForegroundColor Cyan
$viserver = Connect-VIServer $target_vcenter -user $target_vcenter_username -password $target_vcenter_password
Write-Host ("  --> Done.")


# CLEAN UP ANY RESIDUAL TEMPORARY CUSTOMIZATION SPECS IN CASE THEY EXIST
if (Get-OSCustomizationSpec $jumphost_name -ErrorAction SilentlyContinue) {
    Remove-OSCustomizationSpec $jumphost_name -Confirm:$false
}


# CREATE NEW TEMPORARY CUSTOMIZATION SPEC BASED ON TEMPLATE CUSTOMIZATION SPEC
Write-Host ("`n")
Write-Host ("Create new temporary vmware customization specification.") -ForegroundColor Cyan
$customspec = Get-OSCustomizationSpec -Name "windows_jumphost_spec" -Server $viserver | New-OSCustomizationSpec -Name $jumphost_name -Type NonPersistent
Write-Host ("  --> Done.")


# UPDATE NEW TEMPORARY CUSTOMIZATION SPEC WITH STATIC IP ADDRESS INFO
Write-Host ("`n")
Write-Host ("Setting static ip address within temporary vmware customization specification.") -ForegroundColor Cyan
Get-OSCustomizationNicMapping -OSCustomizationSpec $customspec | Set-OSCustomizationNicMapping -IPMode UseStaticIP -IPAddress $ip -SubnetMask $mgmt_subnetmask -DefaultGateway $mgmt_subnet_gateway -Dns $ad_dns_ip | Out-Null
Write-Host ("  --> Done.")


# GET UPDATED TEMPORARY CUSTOMIZATION SPEC
$customspec = Get-OSCustomizationSpec $jumphost_name


# GET SOURCE VM TEMPLATE
Write-Host ("`n")
Write-Host ("Get VM template.") -ForegroundColor Cyan
$template = Get-Template -Name $jumphost_template_name
Write-Host ("  --> Done.")


# CLONE VM TEMPLATE
Write-Host ("`n")
Write-Host ("Create VM clone from VM template.") -ForegroundColor Cyan
New-VM -Name $jumphost_name -Template $template -ResourcePool $hx_clustername -Datastore $target_vcenter_datastore -OSCustomizationSpec $customspec | Out-Null
Write-Host ("  --> Done.")


# SET PORTGROUP
Get-VM $jumphost_name | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $target_vcenter_dvs_portgroup_name -Confirm:$FALSE | Set-NetworkAdapter -StartConnected $true -Confirm:$FALSE


# POWER-ON VM CLONE
Write-Host ("`n")
Write-Host ("Power-on VM clone.") -ForegroundColor Cyan
Start-VM -VM $jumphost_name | Out-Null
Write-Host ("  --> Done.")


# CHECK VM CUSTOMIZATION STATUS
Write-Host ("`n")
Write-Host ("Verifying customization for VM `"$jumphost_name`" has started.") -ForegroundColor Cyan
	while($True)
	{
		$DCvmEvents = Get-VIEvent -Entity $jumphost_name 
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
Write-Host ("Waiting for customization of VM `"$jumphost_name`" to complete.") -ForegroundColor Cyan
Write-Host ("  Note: This may take a few minutes to complete.") -ForegroundColor Green
	while($True)
	{
		$DCvmEvents = Get-VIEvent -Entity $jumphost_name 
		$DCSucceededEvent = $DCvmEvents | Where { $_.GetType().Name -eq "CustomizationSucceeded" }
        $DCFailureEvent = $DCvmEvents | Where { $_.GetType().Name -eq "CustomizationFailed" }
 
		if ($DCFailureEvent)
		{
			Write-Warning -Message "Customization of VM $jumphost_name failed" -Verbose
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
Write-Host ("Waiting for VM `"$jumphost_name`" to complete post-customization reboot.") -ForegroundColor Cyan
Start-Sleep -Seconds 30
Wait-Tools -VM $jumphost_name -TimeoutSeconds 300 | Out-Null
Start-Sleep -Seconds 30
Write-Host ("  --> Done.")


# CLEAN UP TEMPORARY CUSTOMIZATION SPEC
Remove-OSCustomizationSpec $jumphost_name -Confirm:$false -ErrorAction SilentlyContinue