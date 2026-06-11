# Dev helper: call an MCP tool on the rbx-studio-mcp server over stdio
# JSON-RPC, through an ephemeral secondary instance (which dud-proxies to the
# primary). Saves any returned image to -OutImage and prints text content.
# Usage:
#   .\.dev-mcp-call.ps1 -Tool take_screenshot -ArgsJson '{}' -OutImage shot.png
param(
    [Parameter(Mandatory)] [string] $Tool,
    [string] $ArgsJson = "{}",
    [string] $OutImage = "",
    # Studio instance to select first (place name or placeId); the ephemeral
    # MCP process has no sticky selection of its own.
    [string] $Instance = "",
    [int] $TimeoutSec = 120
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "D:\studio-rust-mcp-server-main\target\release\rbx-studio-mcp.exe"
$psi.Arguments = "--stdio"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

try {
    $stdin = $proc.StandardInput
    $stdout = $proc.StandardOutput

    $init = @{ jsonrpc = "2.0"; id = 1; method = "initialize"; params = @{
        protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "dev-driver"; version = "0.0.0" } } } | ConvertTo-Json -Depth 10 -Compress
    $stdin.WriteLine($init); $stdin.Flush()
    $null = $stdout.ReadLine()  # initialize response

    $initialized = @{ jsonrpc = "2.0"; method = "notifications/initialized" } | ConvertTo-Json -Compress
    $stdin.WriteLine($initialized); $stdin.Flush()

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $readTask = $null
    function Read-Response([int] $WantId) {
        $result = $null
        while ((Get-Date) -lt $deadline) {
            if ($null -eq $script:readTask) { $script:readTask = $stdout.ReadLineAsync() }
            if (-not $script:readTask.Wait(1000)) { continue }
            $line = $script:readTask.Result
            $script:readTask = $null
            if ($null -eq $line) { break }
            try { $msg = $line | ConvertFrom-Json } catch { continue }
            if ($msg.id -eq $WantId) { $result = $msg; break }
        }
        return $result
    }

    if ($Instance -ne "") {
        $select = @{ jsonrpc = "2.0"; id = 2; method = "tools/call"; params = @{
            name = "select_studio_instance"; arguments = @{ instance = $Instance } } } | ConvertTo-Json -Depth 20 -Compress
        $stdin.WriteLine($select); $stdin.Flush()
        # Wait for the selection to apply before issuing the main call; tool
        # calls run concurrently on the server.
        $selResponse = Read-Response 2
        if ($null -ne $selResponse) {
            foreach ($content in $selResponse.result.content) {
                if ($content.type -eq "text") { Write-Output "SELECT: $($content.text)" }
            }
        }
    }

    $call = @{ jsonrpc = "2.0"; id = 3; method = "tools/call"; params = @{
        name = $Tool; arguments = ($ArgsJson | ConvertFrom-Json -AsHashtable) } } | ConvertTo-Json -Depth 20 -Compress
    $stdin.WriteLine($call); $stdin.Flush()

    $response = Read-Response 3

    if ($null -eq $response) { Write-Output "TIMEOUT waiting for tool response"; exit 1 }
    if ($response.error) { Write-Output "RPC ERROR: $($response.error | ConvertTo-Json -Compress)"; exit 1 }

    $result = $response.result
    Write-Output "isError: $($result.isError)"
    foreach ($content in $result.content) {
        if ($content.type -eq "text") {
            Write-Output "TEXT: $($content.text)"
        } elseif ($content.type -eq "image") {
            Write-Output "IMAGE: mimeType=$($content.mimeType) base64Length=$($content.data.Length)"
            if ($OutImage -ne "") {
                [System.IO.File]::WriteAllBytes($OutImage, [Convert]::FromBase64String($content.data))
                Write-Output "saved to $OutImage"
            }
        }
    }
} finally {
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
}
