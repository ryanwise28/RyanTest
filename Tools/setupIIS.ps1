$currentDirectory = Get-Location
$hostname = "assets.moonpig.local"

if(Get-Module -Name "WebAdministration"){
	Remove-Module WebAdministration	
}

Import-Module WebAdministration

function Clean-Up()
{
	if (Test-Path iis:\sites\assetsSvc)
	{
		Write-Host "Dropping Moonpig External API web site"
		Remove-Item iis:\sites\assetsSvc -Recurse -Force
	}

	if (Test-Path iis:\appPools\assetsSvcAppPool)
	{
		Write-Host "Dropping application pool"
		Remove-Item iis:\appPools\assetsSvcAppPool -Recurse -Force	
	}
	
	Remove-Hosts-Entry
}

function Create-AppPool()
{
	Write-Host "Creating application pool - assetsSvcAppPool"
	
	$account = Get-AppPoolAccount

	$appPool = New-Item IIS:\AppPools\assetsSvcAppPool
	
	$appPool.managedRuntimeVersion = "v4.0"
	$appPool.processModel.identityType = 3
	$appPool.processModel.userName = "$($account.Name)"
	$appPool.processModel.password = "$($account.Password)"
	
	$appPool | Set-Item
}

function Get-AppPoolAccount()
{
	Write-Host "Using your account $userName for appPool identity"
	$userName = "{0}\{1}" -f [Environment]::UserDomainName, [Environment]::UserName

	$password = Read-Host -AsSecureString "$userName password"
	$password = ConvertTo-PlainText $password
	
	$account = @{ Name = $userName; Password = $password}
	
	return $account
}

function Create-AssetsSvcWebsite()
{
	Write-Host "Creating Moonpig Assets Service Website - $hostname"
	
	$binding = (@{protocol="http"; bindingInformation="127.0.0.1:80:$hostname"})
	
	$webSite = New-Item IIS:\Sites\assetsSvc -physicalPath $currentDirectory\src\Moonpig.Services.Assets -bindings $binding -applicationPool  assetsSvcAppPool
}

function ConvertTo-PlainText([security.securestring]$secure ) 
{
	$marshal = [Runtime.InteropServices.Marshal]
	$marshal::PtrToStringAuto( $marshal::SecureStringToBSTR($secure) )
}

function Remove-Hosts-Entry()
{
	Write-Host "Cleaning up the entry for $hostname from the hosts file"
	
	$hosts = Get-Content $env:windir\system32\drivers\etc\hosts
	$modifiedHostsFile = $hosts | Where-Object {$_ -NotMatch $hostname}
	$modifiedHostsFile | Set-Content $env:windir\system32\drivers\etc\hosts -Force
}

function Add-Hosts-Entry()
{
	Write-Host "Adding entry for $hostname to the hosts file"
	Add-Content $env:windir\system32\drivers\etc\hosts "`n127.0.0.1		$hostname"
}

"----------------------------------------------------------------------"
"Setting up IIS"
"----------------------------------------------------------------------"

Clean-Up

Create-AppPool

Create-AssetsSvcWebsite

Add-Hosts-Entry

"----------------------------------------------------------------------"

