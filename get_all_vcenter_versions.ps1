
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -confirm:$false
function Convert-SubnetTovCenter([string] $subnet)
{
  $vcenter_ip = ((([ipaddress] $subnet).GetAddressBytes()[0..2] -join ".") + ".")+"12"
  return $vcenter_ip
}



$clusters = Get-ChildItem -Path C:/Users/Administrator/Desktop/hxlab/clusters -File #| select Name


$tbl = New-Object System.Data.DataTable "vCenterVersions"
$col1 = New-Object System.Data.DataColumn Name
$col2 = New-Object System.Data.DataColumn Ip
$col3 = New-Object System.Data.DataColumn Version
$col4 = New-Object System.Data.DataColumn Build
$tbl.Columns.Add($col1)
$tbl.Columns.Add($col2)
$tbl.Columns.Add($col3)
$tbl.Columns.Add($col4)

foreach ($cluster in $clusters) {
    $json_input_path = "C:/Users/Administrator/Desktop/hxlab/clusters/"+$cluster.Name
    $json_input_data = Get-Content -Raw -Path $json_input_path | ConvertFrom-Json
    $mgmt_subnet = $json_input_data.clusterdata.network.mgmt.subnet
    $cluster_name = $json_input_data.clusterdata.name
    $vcenter_ip = Convert-SubnetTovCenter([string] $mgmt_subnet)
    $vcenter_password = $json_input_data.clusterdata.password
    $viserver = Connect-VIServer $vcenter_ip -user "administrator@vsphere.local" -password $vcenter_password -ErrorAction SilentlyContinue

    $row = $tbl.NewRow()
    $row.Name = $cluster_name
    $row.Ip = $vcenter_ip
    if ($viserver) {
      $row.Version = $viserver.Version
      $row.Build = $viserver.Build
      Disconnect-VIServer -Server $viserver -Confirm:$false
    } else {
      $row.Version = "n/a"
      $row.Build = "n/a"
    }
    $tbl.Rows.Add($row)
}

$tbl = $tbl | fl

echo $tbl