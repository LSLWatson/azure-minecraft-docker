#Requires -Version 7
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot ".." "scripts" "functions.ps1")

function Assert-True ($Condition, $Message) {
    if (!$Condition) { throw $Message }
}

function Invoke-StatusFixture ($Body, $StatusCode=200, [switch]$ExpectFailure) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $job = Start-ThreadJob -ArgumentList $listener, $Body, $StatusCode -ScriptBlock {
        param ($Listener, $Body, $StatusCode)
        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream)
            $request = $reader.ReadLine()
            if ($request -notlike "GET /v1/join HTTP/*") { throw "Unexpected request: $request" }
            while ($reader.ReadLine()) {}
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $header = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $StatusCode Status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header)
            $stream.Write($bytes)
        } finally {
            $client.Dispose()
        }
    }
    try {
        $failed = $false
        try {
            $status = Get-BedrockServerStatus -ServerFQDN "127.0.0.1" -ServerPort $port
        } catch [System.Net.Http.HttpRequestException], [System.IO.InvalidDataException] {
            $failed = $true
        }
        Assert-True ($failed -eq [bool]$ExpectFailure) "Unexpected status result for $StatusCode / $Body"
        if (!$failed) {
            Assert-True ($status.maxPlayers -eq 4 -and $status.players -eq 0) "Bedrock player counts were not returned."
        }
        $null = Wait-Job $job -Timeout 10
        Receive-Job $job -ErrorAction Stop
    } finally {
        $listener.Stop()
        Stop-Job $job
        Remove-Job $job -Force
    }
}

Invoke-StatusFixture '{"name":"Azure","protocol":2177,"version":"1.26.50","players":0,"maxPlayers":4}'
Invoke-StatusFixture '{}' -ExpectFailure
Invoke-StatusFixture 'not JSON' -ExpectFailure
Invoke-StatusFixture '{"name":"Azure","protocol":2177,"version":"1.26.50","players":5,"maxPlayers":4}' -ExpectFailure
Invoke-StatusFixture '{}' -StatusCode 503 -ExpectFailure

function AzLogin {}
function Invoke-AzCli {
    param([string[]]$Arguments, [switch]$Json)
    Assert-True (($Arguments[0..2] -join " ") -eq "deployment group show") "Unexpected Azure operation."
    Assert-True ($Arguments[6] -eq "fixture-deployment") "The selected deployment name must not be overwritten by helper initialization."
    return @{
        properties = @{
            provisioningState = "Succeeded"
            outputs = @{
                minecraft = @{ value = @(@{ configuration_name = "primary"; container_group_name = "test"; minecraft_server_fqdn = "example.invalid";
                    minecraft_server_port = 19132; minecraft_server_connection = "example.invalid:19132" }) }
            }
        }
    }
}
Set-DeploymentContext -ResourceGroup "test" -DeploymentName "fixture-deployment"
$config = Get-MinecraftConfig
Assert-True ($config.ContainsKey("primary")) "Deployment outputs must be indexed by configuration_name."
$failed = $false
try { Get-MinecraftInstance "missing" } catch { $failed = $true }
Assert-True $failed "Unknown instances must fail explicitly."
$failed = $false
try { Get-DeploymentOutput "missing" } catch { $failed = $true }
Assert-True $failed "Missing deployment outputs must fail explicitly."

function Get-BedrockServerStatus {
    throw [System.Net.Http.HttpRequestException]::new("Fixture connection failure")
}

$failed = $false
try {
    $null = WaitFor-MinecraftServer -Timeout 1 -MaxTries 1 -Interval 1
} catch {
    Assert-True ($_.Exception.Message -like "Bedrock did not respond*") "Unexpected readiness error: $_"
    $failed = $true
}
Assert-True $failed "Readiness must fail rather than report success for an unreachable server."

function Get-BedrockServerStatus {
    return [pscustomobject]@{ version = "1.26.50"; players = 0; maxPlayers = 4 }
}
Assert-True (WaitFor-MinecraftServer -Timeout 1 -MaxTries 1) "Readiness must succeed for valid Bedrock status."

$parseErrors = @()
Get-ChildItem (Join-Path $PSScriptRoot ".." "scripts") -Filter "*.ps1" | ForEach-Object {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    $parseErrors += $errors
}
Assert-True ($parseErrors.Count -eq 0) "PowerShell parse errors: $parseErrors"
Write-Host "PowerShell Bedrock status, readiness failure/success, and syntax checks passed."

$entrypoint = Get-Content (Join-Path $PSScriptRoot ".." "infra" "assets" "entrypoint.sh") -Raw
$bash = (Get-Command bash -ErrorAction Stop).Source
function Invoke-EntrypointFixture ($Prefix) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($bash)
    $startInfo.ArgumentList.Add("-s")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Prefix + "`n" + $entrypoint)
        $process.StandardInput.Close()
        if (!$process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id -Force
            throw "Entrypoint fixture timed out."
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        return @{ Code = $process.ExitCode; Output = $output; Error = $errorOutput }
    } finally {
        $process.Dispose()
    }
}

$prefix = @'
export SERVER_PUBLIC_HOSTNAME="bedrock-test.westeurope.azurecontainer.io"
export SERVER_UDP_PORT_START=19140 SERVER_UDP_PORT_END=19143
sleep() { :; }
exec() { printf 'STARTED:%s\n' "$SERVER_UDP_PORTS"; }
'@
$result = Invoke-EntrypointFixture ($prefix + "`n" + 'getent() { echo "203.0.113.7 STREAM"; }')
Assert-True ($result.Code -eq 0 -and $result.Output.Contains("STARTED:203.0.113.7:19140-19143:19140-19143")) "Entrypoint must advertise the resolved inbound IP and then run the image entrypoint: $($result.Error)"
$result = Invoke-EntrypointFixture ($prefix + "`n" + 'getent() { return 1; }')
Assert-True ($result.Code -eq 1 -and $result.Error.Contains("ERROR: cannot resolve ACI public address")) "Entrypoint must fail explicitly when public DNS cannot be resolved."
Write-Host "Bedrock startup public-IP advertisement and DNS failure checks passed."
