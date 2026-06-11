# Dev helper: drive the MCP server's HTTP /proxy endpoint directly,
# bypassing the MCP stdio transport. Used for testing new tools during
# development. Usage:
#   . .\.dev-proxy.ps1
#   Invoke-McpTool -Tool RunCode -Args @{ command = "print('hi')" } -Target edit
function Invoke-McpTool {
    param(
        [Parameter(Mandatory)] [string] $Tool,
        [hashtable] $Args = @{},
        [ValidateSet("edit", "server", "client")] [string] $Target = "edit",
        [int] $TimeoutSec = 320
    )
    $body = @{
        args   = @{ $Tool = $Args }
        id     = [guid]::NewGuid().ToString()
        target = $Target
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "http://127.0.0.1:44755/proxy" -Method Post `
        -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
}
