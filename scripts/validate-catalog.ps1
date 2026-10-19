param([string]$Image = "beamvoice:working")

$ErrorActionPreference = "Stop"
$name = "beamvoice-catalog-check-$PID"
$volume = "$name-data"
$credentials = Join-Path $env:TEMP "$name.json"
function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [BitConverter]::ToString($bytes).Replace("-", "")
}
$admin = New-Token
$member = New-Token
@(
    @{ token = $admin; user = "admin"; rooms = @("lab"); admin = $true },
    @{ token = $member; user = "member"; rooms = @("lab") }
) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $credentials -Encoding utf8

function Start-Server {
    docker run -d --name $name --read-only --tmpfs /tmp `
        -e BEAMVOICE_ALLOW_INSECURE=true `
        -e BEAMVOICE_CREDENTIALS_FILE=/run/credentials.json `
        -v "${credentials}:/run/credentials.json:ro" `
        -v "${volume}:/app/data" `
        -p 127.0.0.1:18081:8080 $Image | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker container failed to start" }
    for ($i = 0; $i -lt 30; $i++) {
        try {
            Invoke-RestMethod http://127.0.0.1:18081/health | Out-Null
            return
        } catch { Start-Sleep -Milliseconds 500 }
    }
    throw "Server health check failed"
}

function Request([string]$Method, [string]$Path, [string]$Token, [object]$Body = $null) {
    $args = @{ Method = $Method; Uri = "http://127.0.0.1:18081$Path";
               Headers = @{ Authorization = "Bearer $Token" } }
    if ($null -ne $Body) {
        $args.ContentType = "application/json"
        $args.Body = ConvertTo-Json -InputObject $Body -Compress
    }
    Invoke-RestMethod @args
}

try {
    Start-Server
    Request POST /api/servers $admin @{ id = "lab"; name = "Lab" } | Out-Null
    Request POST /api/servers/lab/channels $admin @{ id = "general"; name = "General" } | Out-Null
    Request PUT /api/servers/lab/channels/general $admin @{ name = "Voice" } | Out-Null
    $catalog = Request GET /api/servers $member
    if ($catalog.servers.Count -ne 1 -or $catalog.servers[0].channels[0].name -ne "Voice") {
        throw "Member catalog view is incorrect"
    }
    try {
        Request DELETE /api/servers/lab/channels/general $member | Out-Null
        throw "Member was allowed to delete a channel"
    } catch {
        if ([int]$_.Exception.Response.StatusCode -ne 403) { throw }
    }
    docker rm -f $name | Out-Null
    Start-Server
    $catalog = Request GET /api/servers $admin
    if ($catalog.servers[0].channels[0].name -ne "Voice") {
        throw "Catalog was not persisted across container restart"
    }
    Request DELETE /api/servers/lab/channels/general $admin | Out-Null
    Request PUT /api/servers/lab $admin @{ name = "Renamed" } | Out-Null
    Request DELETE /api/servers/lab $admin | Out-Null
    if ((Request GET /api/servers $admin).servers.Count -ne 0) {
        throw "Server deletion failed"
    }
    Write-Output "Catalog CRUD, ACL, and Docker volume persistence passed"
} finally {
    docker rm -f $name 2>$null | Out-Null
    docker volume rm $volume 2>$null | Out-Null
    Remove-Item -LiteralPath $credentials -ErrorAction SilentlyContinue
}
