param(
    [string]$ChromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $Root
$ShotDir = Join-Path $RepoRoot "tmp\maquette-shots"
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

function Invoke-Cdp {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [int]$Id,
        [string]$Method,
        [hashtable]$Params
    )
    $payload = @{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $Socket.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).Wait()
    do {
        $chunks = [System.Collections.Generic.List[byte]]::new()
        do {
            $buffer = New-Object byte[] 65536
            $result = $Socket.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                [Threading.CancellationToken]::None
            ).Result
            for ($index = 0; $index -lt $result.Count; $index++) {
                $chunks.Add($buffer[$index])
            }
        } while (-not $result.EndOfMessage)
        $json = [Text.Encoding]::UTF8.GetString($chunks.ToArray()) | ConvertFrom-Json
    } while ($json.id -ne $Id)
    return $json
}

function Capture-Maquette {
    param(
        [string]$Platform,
        [int]$Width,
        [int]$Height,
        [int]$Port
    )
    $html = (Resolve-Path (Join-Path $Root "$Platform\index.html")).Path.Replace("\", "/")
    $profile = Join-Path $RepoRoot "tmp\chrome-cdp-$Platform-userflow"
    if (Test-Path $profile) {
        Remove-Item -LiteralPath $profile -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $profile | Out-Null

    $process = Start-Process -FilePath $ChromePath -ArgumentList @(
        "--headless=new",
        "--disable-gpu",
        "--disable-extensions",
        "--remote-debugging-port=$Port",
        "--window-size=1440,900",
        "--user-data-dir=$profile",
        "about:blank"
    ) -PassThru -WindowStyle Hidden

    try {
        Start-Sleep -Seconds 1
        $tabs = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 5
        $page = $tabs | Where-Object { $_.type -eq "page" } | Select-Object -First 1
        if (-not $page) {
            throw "No Chrome page target for $Platform."
        }

        $socket = [System.Net.WebSockets.ClientWebSocket]::new()
        $socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
        try {
            Invoke-Cdp $socket 1 "Emulation.setDeviceMetricsOverride" @{
                width = $Width
                height = $Height
                deviceScaleFactor = 1
                mobile = ($Platform -eq "mobile")
            } | Out-Null
            Invoke-Cdp $socket 2 "Page.navigate" @{ url = "file:///$html" } | Out-Null
            Start-Sleep -Seconds 4
            Invoke-Cdp $socket 3 "Runtime.evaluate" @{
                expression = "document.querySelector('[data-action=save-nickname]')?.click()"
                returnByValue = $true
            } | Out-Null
            Start-Sleep -Milliseconds 500

            $mainShot = Invoke-Cdp $socket 4 "Page.captureScreenshot" @{
                format = "png"
                fromSurface = $true
            }
            [IO.File]::WriteAllBytes(
                (Join-Path $ShotDir "$Platform-main.png"),
                [Convert]::FromBase64String($mainShot.result.data)
            )

            Invoke-Cdp $socket 5 "Runtime.evaluate" @{
                expression = "document.querySelector('[data-action=open-chat]')?.click()"
                returnByValue = $true
            } | Out-Null
            Start-Sleep -Milliseconds 500

            $chatShot = Invoke-Cdp $socket 6 "Page.captureScreenshot" @{
                format = "png"
                fromSurface = $true
            }
            [IO.File]::WriteAllBytes(
                (Join-Path $ShotDir "$Platform-chat.png"),
                [Convert]::FromBase64String($chatShot.result.data)
            )

            $metricsExpression = @'
(() => ({
  viewport: { w: innerWidth, h: innerHeight },
  body: {
    scrollWidth: document.body.scrollWidth,
    clientWidth: document.body.clientWidth
  },
  appText: document.getElementById('app').innerText.slice(0, 220),
  hasUnresolvedRuntimePlaceholder:
    document.getElementById('app').innerHTML.includes('{{') ||
    document.getElementById('overlay-root').innerHTML.includes('{{'),
  openChatButtons: document.querySelectorAll('[data-action=open-chat]').length,
  hasComposer: !!document.querySelector('.composer')
}))()
'@
            $metrics = Invoke-Cdp $socket 7 "Runtime.evaluate" @{
                expression = $metricsExpression
                returnByValue = $true
            }
            $value = $metrics.result.result.value

            if ($Platform -eq "mobile") {
                Invoke-Cdp $socket 8 "Runtime.evaluate" @{
                    expression = "document.querySelector('[data-action=back]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 200
                Invoke-Cdp $socket 9 "Runtime.evaluate" @{
                    expression = "document.querySelector('.header-actions [data-action=open-new-contact]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 300
                $addShot = Invoke-Cdp $socket 10 "Page.captureScreenshot" @{
                    format = "png"
                    fromSurface = $true
                }
                [IO.File]::WriteAllBytes(
                    (Join-Path $ShotDir "mobile-add-code-modal.png"),
                    [Convert]::FromBase64String($addShot.result.data)
                )
                Invoke-Cdp $socket 11 "Runtime.evaluate" @{
                    expression = "document.querySelector('[data-action=close-modal]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 200
                Invoke-Cdp $socket 12 "Runtime.evaluate" @{
                    expression = "document.querySelector('.header-actions [data-action=open-qr]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 300
                $qrShot = Invoke-Cdp $socket 13 "Page.captureScreenshot" @{
                    format = "png"
                    fromSurface = $true
                }
                [IO.File]::WriteAllBytes(
                    (Join-Path $ShotDir "mobile-my-code-modal.png"),
                    [Convert]::FromBase64String($qrShot.result.data)
                )
                Invoke-Cdp $socket 14 "Runtime.evaluate" @{
                    expression = "document.querySelector('[data-action=close-modal]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 200
                Invoke-Cdp $socket 15 "Runtime.evaluate" @{
                    expression = "document.querySelector('[data-action=open-account]')?.click()"
                    returnByValue = $true
                } | Out-Null
                Start-Sleep -Milliseconds 300
                $accountExpression = @'
(() => ({
  text: document.getElementById('app').innerText,
  hasLiveCode: /\b\d{8}\b/.test(document.getElementById('app').innerText)
}))()
'@
                $accountMetrics = Invoke-Cdp $socket 16 "Runtime.evaluate" @{
                    expression = $accountExpression
                    returnByValue = $true
                }
                $accountShot = Invoke-Cdp $socket 17 "Page.captureScreenshot" @{
                    format = "png"
                    fromSurface = $true
                }
                [IO.File]::WriteAllBytes(
                    (Join-Path $ShotDir "mobile-account-no-code.png"),
                    [Convert]::FromBase64String($accountShot.result.data)
                )
                $value | Add-Member -NotePropertyName accountHasLiveCode -NotePropertyValue $accountMetrics.result.result.value.hasLiveCode
            }

            return $value
        } finally {
            $socket.Dispose()
        }
    } finally {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

$result = [ordered]@{
    mobile = Capture-Maquette "mobile" 390 844 9230
    desktop = Capture-Maquette "desktop" 1440 900 9231
}

$result | ConvertTo-Json -Depth 8
