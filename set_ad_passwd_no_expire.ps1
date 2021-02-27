param ($name)
if ($name -eq $null) {
    $name = read-host -Prompt "Please enter cluster name corresponding to json config file: "
}


function Convert-SubnetToAD_DNS([string] $subnet)
{
  $ad_dns_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"10"
  return $ad_dns_ip
}


$json_input_path = "C:/Users/Administrator/Desktop/hxlab/clusters/"+$name+".json"
$json_input_data = Get-Content -Raw -Path $json_input_path | ConvertFrom-Json
$cluster_password = $json_input_data.clusterdata.password
$mgmt_subnet = $json_input_data.clusterdata.network.mgmt.subnet
$hx_clustername = $json_input_data.clusterdata.name
$ad_vmname = $hx_clustername+"_ad_dns"
$ad_dns_ip = Convert-SubnetToAD_DNS([string] $mgmt_subnet)




# CREATE CREDENTIAL FOR PSSESSION
$pass = $cluster_password | ConvertTo-SecureString -asPlainText -Force
$username = "administrator"
$credential = New-Object System.Management.Automation.PSCredential($username,$pass)


# CREATE NEW PSSESSION
Write-Host ("`n")
Write-Host ("Creating remote powershell session to VM `"$ad_vmname`".") -ForegroundColor Cyan
$adserver = New-PSSession -Name 'adserver' -ComputerName $ad_dns_ip -Credential $credential
Write-Host ("  --> Done.")

# SET ADMINISTRATOR PASSWORD TO NEVER EXPIRE
Write-Host ("`n")
Write-Host ("Setting Administrator password to never expire") -ForegroundColor Cyan
Invoke-Command -Session $adserver -ScriptBlock {$user = Get-ADUser -Filter 'Name -like "Administrator"' | select -expand ObjectGUID; Set-ADUser -Identity $user -PasswordNeverExpires $true} | Out-Null
Write-Host ("  --> Done.")


# CLOSE PSSESSION
Write-Host ("`n")
Write-Host ("Closing remote powershell session to VM `"$ad_vmname`".") -ForegroundColor Cyan
Remove-PSSession -Session $adserver
Write-Host ("  --> Done.")