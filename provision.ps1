# NB this script is run as the SYSTEM user.
# NB this script must execute is less than 90 minutes.
# see https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/custom-script-windows
Start-Transcript -Path c:\AzureData\provision-log.txt
Set-StrictMode -Version Latest
$FormatEnumerationLimit = -1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap {
    Write-Output "ERROR: $_"
    Write-Output (($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1')
    Write-Output (($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1')
    Exit 1
}

function Write-Title($title) {
    Write-Output "#`n# $title`n#"
}

# wrap the choco command (to make sure this script aborts when it fails).
function Start-Choco([string[]]$Arguments, [int[]]$SuccessExitCodes=@(0)) {
    $command, $commandArguments = $Arguments
    if ($command -eq 'install') {
        $Arguments = @($command, '--no-progress') + $commandArguments
    }
    for ($n = 0; $n -lt 10; ++$n) {
        if ($n) {
            # NB sometimes choco fails with "The package was not found with the source(s) listed."
            #    but normally its just really a transient "network" error.
            Write-Host "Retrying choco install..."
            Start-Sleep -Seconds 3
        }
        &C:\ProgramData\chocolatey\bin\choco.exe @Arguments
        if ($SuccessExitCodes -Contains $LASTEXITCODE) {
            return
        }
    }
    throw "$(@('choco')+$Arguments | ConvertTo-Json -Compress) failed with exit code $LASTEXITCODE"
}
function choco {
    Start-Choco $Args
}

function exec([ScriptBlock]$externalCommand, [string]$stderrPrefix='', [int[]]$successExitCodes=@(0)) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        &$externalCommand 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                "$stderrPrefix$_"
            } else {
                "$_"
            }
        }
        if ($LASTEXITCODE -notin $successExitCodes) {
            throw "$externalCommand failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $eap
    }
}

# dump our environment for troubleshoot purposes.
Write-Title 'PSVersionTable'
$PSVersionTable
Write-Title 'whoami'
whoami /all
Write-Title 'environment variables'
Get-ChildItem env: `
    | Format-Table -AutoSize `
    | Out-String -Width 4096 -Stream `
    | ForEach-Object {$_.Trim()}

# expand the C drive when there is disk available.
$partition = Get-Partition -DriveLetter C
$partitionSupportedSize = Get-PartitionSupportedSize -DriveLetter C
if ($partition.Size -ne $partitionSupportedSize.SizeMax) {
    Write-Host "Expanding the C: partition from $($partition.Size) to $($partitionSupportedSize.SizeMax) bytes..."
    Resize-Partition -DriveLetter C -Size $partitionSupportedSize.SizeMax
}

# format all uninitialized disks (the data disks).
Get-Disk `
    | Where-Object { $_.PartitionStyle -eq 'raw' } `
    | ForEach-Object {
        Write-Host "Initializing disk #$($_.Number) ($($_.Size) bytes)..."
        $volume = $_ `
            | Initialize-Disk -PartitionStyle MBR -PassThru `
            | New-Partition -AssignDriveLetter -UseMaximumSize `
            | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'data' -Confirm:$false
        Write-Host "Initialized disk #$($_.Number) ($($_.Size) bytes) as $($volume.DriveLetter):."
    }

# install chocolatey.
Invoke-WebRequest https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
Import-Module C:\ProgramData\chocolatey\helpers\chocolateyInstaller.psm1
Update-SessionEnvironment

# install dependencies.
choco install -y nssm
choco install -y nodejs-lts
Update-SessionEnvironment
node --version
npm --version

# create an example http server and run it as a windows service.
$serviceName = 'app'
$serviceUsername = "NT SERVICE\$serviceName"
$serviceHome = 'c:\app'
mkdir -Force $serviceHome | Out-Null
Push-Location $serviceHome
Set-Content -Encoding ascii -Path main.js -Value @'
const http = require("http");

function createRequestListener(metadata) {
    return (request, response) => {
        const serverAddress = `${request.socket.localAddress}:${request.socket.localPort}`;
        const clientAddress = `${request.socket.remoteAddress}:${request.socket.remotePort}`;
        const message = `VM Name: ${metadata.compute.name}
Server Address: ${serverAddress}
Client Address: ${clientAddress}
Request URL: ${request.url}
`; 
        console.log(message);
        response.writeHead(200, {"Content-Type": "text/plain"});
        response.write(message);
        response.end();
    };
}

function main(metadata, port) {
    const server = http.createServer(createRequestListener(metadata));
    server.listen(port);
}

// see https://docs.microsoft.com/en-us/azure/virtual-machines/linux/instance-metadata-service#retrieving-all-metadata-for-an-instance
http.get(
    "http://169.254.169.254/metadata/instance?api-version=2017-08-01",
    {
        headers: {
            Metadata: "true"
        }
    },
    (response) => {
        let data = "";
        response.on("data", (chunk) => data += chunk);
        response.on("end", () => {
            const metadata = JSON.parse(data);
            main(metadata, process.argv[2] || process.env.PORT || 80);
        });
    }
).on("error", (error) => console.log("Error fetching metadata: " + error.message));
'@
Set-Content -Encoding ascii -Path package.json -Value @'
{
    "name": "app",
    "description": "example application",
    "version": "1.0.0",
    "license": "MIT",
    "main": "main.js",
    "dependencies": {}
}
'@
exec {npm install}

# create the windows service using a managed service account.
Write-Host "Creating the $serviceName service..."
nssm install $serviceName (Get-Command node.exe).Path
nssm set $serviceName AppParameters main.js 80
nssm set $serviceName AppDirectory $serviceHome
nssm set $serviceName Start SERVICE_AUTO_START
nssm set $serviceName AppRotateFiles 1
nssm set $serviceName AppRotateOnline 1
nssm set $serviceName AppRotateSeconds 86400
nssm set $serviceName AppRotateBytes 1048576
nssm set $serviceName AppStdout $serviceHome\logs\service-stdout.log
nssm set $serviceName AppStderr $serviceHome\logs\service-stderr.log
[string[]]$result = sc.exe sidtype $serviceName unrestricted
if ($result -ne '[SC] ChangeServiceConfig2 SUCCESS') {
    throw "sc.exe sidtype failed with $result"
}
[string[]]$result = sc.exe config $serviceName obj= $serviceUsername
if ($result -ne '[SC] ChangeServiceConfig SUCCESS') {
    throw "sc.exe config failed with $result"
}
[string[]]$result = sc.exe failure $serviceName reset= 0 actions= restart/60000
if ($result -ne '[SC] ChangeServiceConfig2 SUCCESS') {
    throw "sc.exe failure failed with $result"
}

# create the logs directory and grant fullcontrol to the service.
$logsDirectory = mkdir "$serviceHome\logs"
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
@(
    'SYSTEM'
    'Administrators'
    $serviceUsername
) | ForEach-Object {
    $acl.AddAccessRule((
        New-Object `
            Security.AccessControl.FileSystemAccessRule(
                $_,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow')))
}
$logsDirectory.SetAccessControl($acl)

# finally start the service.
Start-Service $serviceName
Pop-Location

# create a firewall rule to accept incomming traffic on port 80.
New-NetFirewallRule `
    -Name 'app' `
    -DisplayName 'app' `
    -Direction Inbound `
    -LocalPort 80 `
    -Protocol TCP `
    -Action Allow `
    | Out-Null

# try it.
Start-Sleep -Milliseconds 500
Invoke-RestMethod http://localhost/try
