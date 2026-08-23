#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('cpu','cuda')]
    [string]$Backend = 'cpu',
    [string]$ZipPath,
    [string]$ExpectedZipSha256,
    [string]$ModelPath = (Join-Path $env:LOCALAPPDATA 'NeMoSpeech\models\nvidia\nemotron-3.5-asr-streaming-0.6b\1c8deaecc64b91f034d73e08dd8b64625eb3395d\nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'),
    [string]$WorkRoot,
    [string]$EvidencePath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$fixedModel = [ordered]@{
    owner='nvidia'
    repo='nemotron-3.5-asr-streaming-0.6b'
    revision='1c8deaecc64b91f034d73e08dd8b64625eb3395d'
    filename='nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'
    size=741548352L
    sha256='A5C435F294EEA8F88CE68DD27B8C3BFEA7F777CB2FBBA04FCD30EAA555F429AE'
}

function Test-FixedModelContract {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][long]$Size,
        [Parameter(Mandatory)][string]$Sha256
    )
    return $Owner -ceq 'nvidia' -and
        $Repo -ceq 'nemotron-3.5-asr-streaming-0.6b' -and
        $Revision -ceq '1c8deaecc64b91f034d73e08dd8b64625eb3395d' -and
        $Filename -ceq 'nemotron-3.5-asr-streaming-0.6b.q8_0.gguf' -and
        $Size -eq 741548352L -and
        $Sha256 -ceq 'A5C435F294EEA8F88CE68DD27B8C3BFEA7F777CB2FBBA04FCD30EAA555F429AE'
}

function Test-ReadyAcceptanceContract {
    param([Parameter(Mandatory)][psobject]$Ready, [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$ExpectedBackend)
    foreach ($name in @('ready','device','capabilities','runtime_capabilities')) {
        if ($null -eq $Ready.PSObject.Properties[$name]) { return $false }
    }
    $runtime = @($Ready.runtime_capabilities)
    $capabilities = @($Ready.capabilities)
    $expectedDevice = if ($ExpectedBackend -eq 'cuda') { 'cuda:0' } else { 'cpu' }
    return [bool]$Ready.ready -and [string]$Ready.device -ceq $expectedDevice -and
        $capabilities -ccontains 'asr' -and $runtime.Count -eq 1 -and
        [string]$runtime[0] -ceq 'realtime-language-v1'
}

function Test-LanguageAcceptanceContract {
    param([Parameter(Mandatory)][psobject]$Observation, [Parameter(Mandatory)][ValidateSet('en','es')][string]$ExpectedPrefix)
    foreach ($name in @('result_nonempty','language','ambiguous')) {
        if ($null -eq $Observation.PSObject.Properties[$name]) { return $false }
    }
    if (-not [bool]$Observation.result_nonempty -or [bool]$Observation.ambiguous) { return $false }
    return [string]$Observation.language -match ('^(?i:' + [regex]::Escape($ExpectedPrefix) + ')(?:[-_]|$)')
}

function Test-CausalBackendContract {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Diagnostic,
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$ExpectedBackend
    )
    $noFallback = $Diagnostic -notmatch '(?im)fall(?:ing)?\s+back'
    if ($ExpectedBackend -eq 'cpu') {
        return $noFallback -and $Diagnostic -match '(?im)^\[asr\].*\bbackend=CPU\b' -and
            $Diagnostic -notmatch '(?im)^\[asr\].*\bbackend=CUDA0\b'
    }
    return $noFallback -and
        $Diagnostic -match '(?im)^\[asr\].*\bbackend=CUDA0\b' -and
        $Diagnostic -match '(?im)ggml_backend_cuda_graph_compute:\s*CUDA graph warmup complete' -and
        $Diagnostic -match '(?im)Device\s+0:.*RTX\s+3060.*compute capability\s+8\.6' -and
        $Diagnostic -notmatch '(?im)^\[asr\].*\bbackend=CPU\b'
}

function Test-PublicAcceptanceEvidenceContract {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    return $Json -notmatch '(?i)(?:[A-Z]:\\(?:\\)?Users\\|[A-Z]:/(?:Users)/|/Users/)' -and
        $Json -notmatch '(?i)"(?:text|transcript|delta|words?)"\s*:' -and
        $Json -notmatch '(?i)"(?:authorization|api[_-]?key|bearer|token|secret|password)"\s*:'
}

function Write-Utf8Json {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'EvidencePath must have a parent directory.' }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $json = $Value | ConvertTo-Json -Depth 12
    if (-not (Test-PublicAcceptanceEvidenceContract -Json $json)) { throw 'Acceptance evidence privacy contract failed.' }
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
    return $json
}

if ($SelfTest) {
    $validModel = @{
        Owner='nvidia'; Repo='nemotron-3.5-asr-streaming-0.6b'; Revision='1c8deaecc64b91f034d73e08dd8b64625eb3395d'
        Filename='nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'; Size=741548352L
        Sha256='A5C435F294EEA8F88CE68DD27B8C3BFEA7F777CB2FBBA04FCD30EAA555F429AE'
    }
    $wrongRevision = $validModel.Clone(); $wrongRevision.Revision = '0' * 40
    $wrongSize = $validModel.Clone(); $wrongSize.Size = 1L
    $wrongHash = $validModel.Clone(); $wrongHash.Sha256 = '0' * 64
    $cases = @(
        [pscustomobject]@{ name='fixed-model-green'; passed=(Test-FixedModelContract @validModel) },
        [pscustomobject]@{ name='wrong-revision-red'; passed=(-not (Test-FixedModelContract @wrongRevision)) },
        [pscustomobject]@{ name='wrong-size-red'; passed=(-not (Test-FixedModelContract @wrongSize)) },
        [pscustomobject]@{ name='wrong-hash-red'; passed=(-not (Test-FixedModelContract @wrongHash)) },
        [pscustomobject]@{ name='ready-green'; passed=(Test-ReadyAcceptanceContract -ExpectedBackend cuda -Ready ([pscustomobject]@{ ready=$true; device='cuda:0'; capabilities=@('asr'); runtime_capabilities=@('realtime-language-v1') })) },
        [pscustomobject]@{ name='ready-missing-capability-red'; passed=(-not (Test-ReadyAcceptanceContract -ExpectedBackend cuda -Ready ([pscustomobject]@{ ready=$true; device='cuda:0'; capabilities=@('asr'); runtime_capabilities=@() }))) },
        [pscustomobject]@{ name='ready-duplicate-capability-red'; passed=(-not (Test-ReadyAcceptanceContract -ExpectedBackend cuda -Ready ([pscustomobject]@{ ready=$true; device='cuda:0'; capabilities=@('asr'); runtime_capabilities=@('realtime-language-v1','realtime-language-v1') }))) },
        [pscustomobject]@{ name='language-green'; passed=(Test-LanguageAcceptanceContract -ExpectedPrefix es -Observation ([pscustomobject]@{ result_nonempty=$true; language='es-ES'; ambiguous=$false })) },
        [pscustomobject]@{ name='language-ambiguous-red'; passed=(-not (Test-LanguageAcceptanceContract -ExpectedPrefix es -Observation ([pscustomobject]@{ result_nonempty=$true; language='es-ES'; ambiguous=$true }))) },
        [pscustomobject]@{ name='language-missing-red'; passed=(-not (Test-LanguageAcceptanceContract -ExpectedPrefix es -Observation ([pscustomobject]@{ result_nonempty=$true; language=''; ambiguous=$false }))) },
        [pscustomobject]@{ name='cuda-causal-green'; passed=(Test-CausalBackendContract -ExpectedBackend cuda -Diagnostic "Device 0: NVIDIA GeForce RTX 3060, compute capability 8.6`n[asr] model=fixed head=rnnt backend=CUDA0`nggml_backend_cuda_graph_compute: CUDA graph warmup complete") },
        [pscustomobject]@{ name='cuda-fallback-red'; passed=(-not (Test-CausalBackendContract -ExpectedBackend cuda -Diagnostic "Device 0: NVIDIA GeForce RTX 3060, compute capability 8.6`n[asr] backend=CUDA0`nfalling back to CPU`nggml_backend_cuda_graph_compute: CUDA graph warmup complete")) },
        [pscustomobject]@{ name='cuda-model-cpu-red'; passed=(-not (Test-CausalBackendContract -ExpectedBackend cuda -Diagnostic "Device 0: NVIDIA GeForce RTX 3060, compute capability 8.6`n[asr] backend=CPU`nggml_backend_cuda_graph_compute: CUDA graph warmup complete")) },
        [pscustomobject]@{ name='evidence-green'; passed=(Test-PublicAcceptanceEvidenceContract -Json '{"schema":"diagnotes-runtime-candidate-acceptance-v1","result_nonempty":true}') },
        [pscustomobject]@{ name='evidence-raw-path-red'; passed=(-not (Test-PublicAcceptanceEvidenceContract -Json '{"p":"C:\Users\Owner\model"}')) },
        [pscustomobject]@{ name='evidence-escaped-path-red'; passed=(-not (Test-PublicAcceptanceEvidenceContract -Json '{"p":"C:\\Users\\Owner\\model"}')) },
        [pscustomobject]@{ name='evidence-content-red'; passed=(-not (Test-PublicAcceptanceEvidenceContract -Json '{"transcript":"private"}')) }
    )
    $result = [ordered]@{ schema='diagnotes-runtime-candidate-self-test-v1'; cases=$cases; passed=(@($cases | Where-Object { -not $_.passed }).Count -eq 0) }
    $json = $result | ConvertTo-Json -Depth 6
    $json
    if (-not $result.passed) { throw 'Runtime candidate self-test failed.' }
    exit 0
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$WorkingDirectory
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Process did not start.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Process exceeded its bounded timeout.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $result = [pscustomobject]@{ exit_code=$process.ExitCode; stdout=$stdout; stderr=$stderr }
    $process.Dispose()
    return $result
}

function New-SilentFixture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LanguageHex,
        [Parameter(Mandatory)][string]$Phrase
    )
    $voice = $null
    $stream = $null
    try {
        $voice = New-Object -ComObject SAPI.SpVoice
        $voices = $voice.GetVoices("Language=$LanguageHex", '')
        if ($voices.Count -lt 1) { throw 'Required local SAPI voice is unavailable.' }
        $voice.Voice = $voices.Item(0)
        $stream = New-Object -ComObject SAPI.SpFileStream
        $stream.Open($Path, 3, $false)
        $voice.AudioOutputStream = $stream
        [void]$voice.Speak($Phrase, 0)
        $stream.Close()
    } finally {
        if ($null -ne $stream) { try { $stream.Close() } catch {}; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($stream) }
        if ($null -ne $voice) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($voice) }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 44) {
        throw 'Silent fixture generation failed.'
    }
}

function Get-WavPcm16 {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes,8,4) -cne 'WAVE') {
        throw 'Fixture is not a RIFF/WAVE file.'
    }
    $format = $null
    $data = $null
    $offset = 12
    while ($offset + 8 -le $bytes.Length) {
        $id = [Text.Encoding]::ASCII.GetString($bytes,$offset,4)
        $size = [BitConverter]::ToUInt32($bytes,$offset + 4)
        $body = $offset + 8
        if ($body + $size -gt $bytes.Length) { throw 'WAV chunk exceeds file bounds.' }
        if ($id -ceq 'fmt ') {
            if ($size -lt 16) { throw 'WAV fmt chunk is truncated.' }
            $format = [pscustomobject]@{
                encoding=[BitConverter]::ToUInt16($bytes,$body)
                channels=[BitConverter]::ToUInt16($bytes,$body + 2)
                sample_rate=[BitConverter]::ToUInt32($bytes,$body + 4)
                bits=[BitConverter]::ToUInt16($bytes,$body + 14)
            }
        } elseif ($id -ceq 'data') {
            $data = [byte[]]::new([int]$size)
            [Array]::Copy($bytes,$body,$data,0,[int]$size)
        }
        $offset = $body + [int]$size + ([int]$size % 2)
    }
    if ($null -eq $format -or $null -eq $data -or $format.encoding -ne 1 -or $format.channels -ne 1 -or $format.bits -ne 16 -or $data.Length -eq 0) {
        throw 'Fixture must be nonempty PCM16 mono WAV.'
    }
    return [pscustomobject]@{ bytes=$data; sample_rate=[int]$format.sample_rate }
}

function Get-LoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Send-WebSocketJson {
    param([Parameter(Mandatory)][Net.WebSockets.ClientWebSocket]$Socket, [Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][Threading.CancellationToken]$Token)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress -Depth 6))
    $segment = [ArraySegment[byte]]::new($bytes)
    $null = $Socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,$Token).GetAwaiter().GetResult()
}

function Receive-WebSocketJson {
    param([Parameter(Mandatory)][Net.WebSockets.ClientWebSocket]$Socket, [Parameter(Mandatory)][Threading.CancellationToken]$Token)
    $memory = [IO.MemoryStream]::new()
    try {
        do {
            $buffer = [byte[]]::new(65536)
            $segment = [ArraySegment[byte]]::new($buffer)
            $received = $Socket.ReceiveAsync($segment,$Token).GetAwaiter().GetResult()
            if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Realtime socket closed before acceptance completed.' }
            $memory.Write($buffer,0,$received.Count)
        } while (-not $received.EndOfMessage)
        return ([Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json -Depth 12)
    } finally { $memory.Dispose() }
}

function Invoke-HttpFixture {
    param([Parameter(Mandatory)][Net.Http.HttpClient]$Client, [Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('en','es')][string]$ExpectedPrefix)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $multipart = [Net.Http.MultipartFormDataContent]::new()
    $fileContent = $null
    $response = $null
    $body = $null
    $recognized = $null
    try {
        $fileContent = [Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($Path))
        $fileContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('audio/wav')
        $multipart.Add($fileContent,'file','fixture.wav')
        $multipart.Add([Net.Http.StringContent]::new('verbose_json'),'response_format')
        $response = $Client.PostAsync($Uri,$multipart).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw 'HTTP fixture request failed.' }
        $document = $body | ConvertFrom-Json -Depth 12
        $recognized = [string]$document.text
        $observation = [pscustomobject]@{ result_nonempty=(-not [string]::IsNullOrWhiteSpace($recognized)); language=[string]$document.language; ambiguous=$false }
        if (-not (Test-LanguageAcceptanceContract -Observation $observation -ExpectedPrefix $ExpectedPrefix)) { throw 'HTTP language acceptance failed.' }
        return [pscustomobject]@{ result_nonempty=$true; language=[string]$observation.language; milliseconds=$timer.ElapsedMilliseconds }
    } finally {
        $recognized = $null
        $body = $null
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $fileContent) { $fileContent.Dispose() }
        $multipart.Dispose()
        $timer.Stop()
    }
}

function Invoke-RealtimeFixture {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][psobject]$Pcm, [Parameter(Mandatory)][ValidateSet('en','es')][string]$ExpectedPrefix)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(180))
    $recognized = $null
    try {
        $null = $socket.ConnectAsync($Uri,$cancel.Token).GetAwaiter().GetResult()
        $created = Receive-WebSocketJson -Socket $socket -Token $cancel.Token
        if ([string]$created.type -cne 'session.created') { throw 'Realtime session did not emit session.created first.' }
        Send-WebSocketJson -Socket $socket -Token $cancel.Token -Value ([ordered]@{ type='session.update'; session=[ordered]@{ sample_rate=$Pcm.sample_rate } })
        $offset = 0
        while ($offset -lt $Pcm.bytes.Length) {
            $count = [Math]::Min(32768,$Pcm.bytes.Length - $offset)
            $segment = [ArraySegment[byte]]::new($Pcm.bytes,$offset,$count)
            $null = $socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Binary,$true,$cancel.Token).GetAwaiter().GetResult()
            $offset += $count
        }
        Send-WebSocketJson -Socket $socket -Token $cancel.Token -Value ([ordered]@{ type='input_audio_buffer.commit' })
        $completed = $false
        $committed = $false
        $language = ''
        $ambiguous = $false
        while (-not ($completed -and $committed)) {
            $event = Receive-WebSocketJson -Socket $socket -Token $cancel.Token
            $type = [string]$event.type
            if ($type -ceq 'error') { throw 'Realtime server returned an error event.' }
            if ($type -ceq 'conversation.item.input_audio_transcription.completed') {
                $recognized = [string]$event.transcript
                $language = if ($null -ne $event.PSObject.Properties['language']) { [string]$event.language } else { '' }
                $ambiguous = $null -ne $event.PSObject.Properties['language_status'] -and [string]$event.language_status -ceq 'ambiguous'
                $event.transcript = $null
                $completed = $true
            } elseif ($type -ceq 'conversation.item.input_audio_transcription.delta' -and $null -ne $event.PSObject.Properties['delta']) {
                $event.delta = $null
            } elseif ($type -ceq 'input_audio_buffer.committed') {
                $committed = $true
            }
            $event = $null
        }
        $observation = [pscustomobject]@{ result_nonempty=(-not [string]::IsNullOrWhiteSpace($recognized)); language=$language; ambiguous=$ambiguous }
        if (-not (Test-LanguageAcceptanceContract -Observation $observation -ExpectedPrefix $ExpectedPrefix)) { throw 'Realtime language acceptance failed.' }
        return [pscustomobject]@{ result_nonempty=$true; language=$language; ambiguous=$false; milliseconds=$timer.ElapsedMilliseconds }
    } finally {
        $recognized = $null
        if ($socket.State -in @([Net.WebSockets.WebSocketState]::Open,[Net.WebSockets.WebSocketState]::CloseReceived)) {
            try { $null = $socket.CloseOutputAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'done',[Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch {}
        }
        $socket.Dispose()
        $cancel.Dispose()
        $timer.Stop()
    }
}

function Resolve-DefenderCli {
    $candidates = @((Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'))
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $platform -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $platform -Filter MpCmdRun.exe -File -Recurse | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
    }
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    if ($existing.Count -lt 1) { throw 'Microsoft Defender CLI is unavailable.' }
    return $existing[0]
}

foreach ($required in @($ZipPath,$ExpectedZipSha256,$WorkRoot,$EvidencePath,$ModelPath)) {
    if ([string]::IsNullOrWhiteSpace($required)) { throw 'Candidate acceptance requires ZIP, hash, model, work root, and evidence path.' }
}
if ($ExpectedZipSha256 -cnotmatch '^[0-9A-F]{64}$') { throw 'Expected ZIP SHA-256 must be uppercase hexadecimal.' }

$allowedBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'DiagNotes\RuntimeBuild')).TrimEnd('\')
$resolvedWork = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
if (-not $resolvedWork.StartsWith($allowedBase + '\',[StringComparison]::OrdinalIgnoreCase) -or $resolvedWork -ceq $allowedBase) {
    throw 'Acceptance work root is outside the bounded local runtime root.'
}
if (Test-Path -LiteralPath $resolvedWork) { throw 'Acceptance work root must be new.' }
$resolvedEvidence = [IO.Path]::GetFullPath($EvidencePath)
if ($resolvedEvidence.StartsWith($resolvedWork + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'EvidencePath must survive acceptance-root cleanup.' }

$server = $null
$serverStdoutTask = $null
$serverStderrTask = $null
$serverStdout = $null
$serverStderr = $null
$cliStdout = $null
$cliStderr = $null
$client = $null
$evidenceJson = $null
try {
    New-Item -ItemType Directory -Path $resolvedWork | Out-Null
    $zip = Get-Item -LiteralPath $ZipPath
    $expectedName = if ($Backend -eq 'cpu') { 'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cpu.zip' } else { 'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cuda-sm75-sm80-sm86-sm89.zip' }
    $zipHash = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
    if ($zip.Name -cne $expectedName -or $zipHash -cne $ExpectedZipSha256) { throw 'Candidate ZIP identity or digest mismatch.' }

    $model = Get-Item -LiteralPath $ModelPath
    $modelFacts = @{
        Owner=$model.Directory.Parent.Parent.Name
        Repo=$model.Directory.Parent.Name
        Revision=$model.Directory.Name
        Filename=$model.Name
        Size=$model.Length
        Sha256=(Get-FileHash -LiteralPath $model.FullName -Algorithm SHA256).Hash
    }
    if (-not (Test-FixedModelContract @modelFacts)) { throw 'Fixed model contract failed.' }

    $extractRoot = Join-Path $resolvedWork 'candidate'
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $extractRoot
    $top = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
    if ($top.Count -ne 1 -or @(Get-ChildItem -LiteralPath $extractRoot -File -Force).Count -ne 0) { throw 'Candidate ZIP must contain exactly one top-level directory.' }
    $candidateRoot = $top[0].FullName
    $exe = Join-Path $candidateRoot 'bin\nemo-speech.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Candidate executable is missing.' }

    $mpStatus = Get-MpComputerStatus
    if (-not $mpStatus.AntivirusEnabled -or -not $mpStatus.RealTimeProtectionEnabled) { throw 'Microsoft Defender is not enabled.' }
    $defender = Invoke-CapturedProcess -FilePath (Resolve-DefenderCli) -Arguments @('-Scan','-ScanType','3','-File',$candidateRoot) -TimeoutSeconds 600
    $defenderOutput = $defender.stdout + $defender.stderr
    if ($defender.exit_code -ne 0) { throw 'Microsoft Defender candidate scan failed.' }
    $defenderOutput = $null

    $fixtureRoot = Join-Path $resolvedWork 'fixtures'
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $fixtures = @(
        [pscustomobject]@{ id='synthetic-en'; prefix='en'; language_hex='409'; phrase='The clinical interpreter verifies a clear sentence.'; path=(Join-Path $fixtureRoot 'en.wav') },
        [pscustomobject]@{ id='synthetic-es'; prefix='es'; language_hex='80A'; phrase='El interprete clinico verifica una frase clara.'; path=(Join-Path $fixtureRoot 'es.wav') }
    )
    foreach ($fixture in $fixtures) { New-SilentFixture -Path $fixture.path -LanguageHex $fixture.language_hex -Phrase $fixture.phrase }

    $port = Get-LoopbackPort
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.WorkingDirectory = (Split-Path -Parent $exe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--json','serve','--asr-model',$model.FullName,'--device',$(if ($Backend -eq 'cuda') { 'cuda:0' } else { 'cpu' }),'--host','127.0.0.1','--port',[string]$port,'--no-ui','--no-warmup')) {
        [void]$start.ArgumentList.Add($argument)
    }
    $server = [Diagnostics.Process]::new()
    $server.StartInfo = $start
    if (-not $server.Start()) { throw 'Candidate server did not start.' }
    $serverStdoutTask = $server.StandardOutput.ReadToEndAsync()
    $serverStderrTask = $server.StandardError.ReadToEndAsync()

    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $baseUri = [uri]"http://127.0.0.1:$port"
    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    $ready = $null
    while ($readyTimer.Elapsed -lt [TimeSpan]::FromMinutes(3)) {
        if ($server.HasExited) { throw 'Candidate server exited before readiness.' }
        try {
            $response = $client.GetAsync([uri]::new($baseUri,'/ready')).GetAwaiter().GetResult()
            $readyBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($response.IsSuccessStatusCode) { $ready = $readyBody | ConvertFrom-Json -Depth 8 }
            $readyBody = $null
            $response.Dispose()
            if ($null -ne $ready -and (Test-ReadyAcceptanceContract -Ready $ready -ExpectedBackend $Backend)) { break }
        } catch { Start-Sleep -Milliseconds 250; continue }
        Start-Sleep -Milliseconds 250
    }
    $readyTimer.Stop()
    if ($null -eq $ready -or -not (Test-ReadyAcceptanceContract -Ready $ready -ExpectedBackend $Backend)) { throw 'Candidate readiness contract failed.' }

    $fixtureEvidence = @()
    foreach ($fixture in $fixtures) {
        $httpResult = @(Invoke-HttpFixture -Client $client -Uri ([uri]::new($baseUri,'/v1/audio/transcriptions')) -Path $fixture.path -ExpectedPrefix $fixture.prefix)
        if ($httpResult.Count -ne 1 -or $null -eq $httpResult[0].PSObject.Properties['result_nonempty']) {
            throw "HTTP observation shape is invalid (count=$($httpResult.Count))."
        }
        $http = $httpResult[0]
        $pcm = Get-WavPcm16 -Path $fixture.path
        $realtimeResult = @(Invoke-RealtimeFixture -Uri ([uri]"ws://127.0.0.1:$port/v1/realtime") -Pcm $pcm -ExpectedPrefix $fixture.prefix)
        if ($realtimeResult.Count -ne 1 -or $null -eq $realtimeResult[0].PSObject.Properties['result_nonempty']) {
            throw "Realtime observation shape is invalid (count=$($realtimeResult.Count))."
        }
        $realtime = $realtimeResult[0]
        $fixtureEvidence += [ordered]@{
            id=$fixture.id
            http=[ordered]@{ status='PASS'; result_nonempty=$http.result_nonempty; language=$http.language; milliseconds=$http.milliseconds }
            realtime=[ordered]@{ status='PASS'; result_nonempty=$realtime.result_nonempty; language=$realtime.language; ambiguous=$realtime.ambiguous; milliseconds=$realtime.milliseconds }
        }
        $pcm.bytes = $null
        $pcm = $null
    }

    $causal = Invoke-CapturedProcess -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -TimeoutSeconds 300 -Arguments @(
        '--verbose','transcribe',$fixtures[0].path,'--model',$model.FullName,'--device',$(if ($Backend -eq 'cuda') { 'cuda:0' } else { 'cpu' }),'--format','json','--no-warmup'
    )
    $cliStdout = $causal.stdout
    $cliStderr = $causal.stderr
    $diagnostic = $cliStderr + "`n" + $cliStdout
    if ($causal.exit_code -ne 0 -or -not (Test-CausalBackendContract -Diagnostic $diagnostic -ExpectedBackend $Backend)) { throw 'Causal backend execution contract failed.' }
    $technical = if ($Backend -eq 'cuda') {
        [ordered]@{
            model_backend_cuda0=($diagnostic -match '(?im)^\[asr\].*\bbackend=CUDA0\b')
            cuda_device_sm86=($diagnostic -match '(?im)Device\s+0:.*RTX\s+3060.*compute capability\s+8\.6')
            cuda_graph_compute=($diagnostic -match '(?im)ggml_backend_cuda_graph_compute:\s*CUDA graph warmup complete')
            fallback_absent=($diagnostic -notmatch '(?im)fall(?:ing)?\s+back')
        }
    } else {
        [ordered]@{
            model_backend_cpu=($diagnostic -match '(?im)^\[asr\].*\bbackend=CPU\b')
            cuda_model_backend_absent=($diagnostic -notmatch '(?im)^\[asr\].*\bbackend=CUDA0\b')
            fallback_absent=($diagnostic -notmatch '(?im)fall(?:ing)?\s+back')
        }
    }
    $diagnostic = $null
    $cliStdout = $null
    $cliStderr = $null

    $evidence = [ordered]@{
        schema='diagnotes-runtime-candidate-acceptance-v1'
        backend=$Backend
        candidate=[ordered]@{ name=$zip.Name; size=$zip.Length; sha256=$zipHash }
        model=[ordered]@{ owner=$modelFacts.Owner; repo=$modelFacts.Repo; revision=$modelFacts.Revision; filename=$modelFacts.Filename; size=$modelFacts.Size; sha256=$modelFacts.Sha256 }
        defender=[ordered]@{ status='PASS'; real_time_protection=$true; scan_exit_code=0 }
        ready=[ordered]@{ status='PASS'; ready=$true; device=[string]$ready.device; capabilities=@($ready.capabilities); runtime_capabilities=@($ready.runtime_capabilities); milliseconds=$readyTimer.ElapsedMilliseconds }
        fixtures=$fixtureEvidence
        causal_backend=[ordered]@{ status='PASS'; details=$technical }
        passed=$true
    }
    $evidenceJson = Write-Utf8Json -Value $evidence -Path $resolvedEvidence
    $evidenceJson
} finally {
    $cliStdout = $null
    $cliStderr = $null
    $evidenceJson = $null
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $server) {
        if (-not $server.HasExited) {
            try { $server.Kill($true); $server.WaitForExit(10000) | Out-Null } catch {}
        }
        if ($null -ne $serverStdoutTask -and $serverStdoutTask.IsCompleted) { $serverStdout = $serverStdoutTask.GetAwaiter().GetResult() }
        if ($null -ne $serverStderrTask -and $serverStderrTask.IsCompleted) { $serverStderr = $serverStderrTask.GetAwaiter().GetResult() }
        $server.Dispose()
    }
    $serverStdout = $null
    $serverStderr = $null
    if (Test-Path -LiteralPath $resolvedWork) {
        $checked = [IO.Path]::GetFullPath($resolvedWork).TrimEnd('\')
        if (-not $checked.StartsWith($allowedBase + '\',[StringComparison]::OrdinalIgnoreCase) -or $checked -ceq $allowedBase) { throw 'Refusing unsafe acceptance cleanup.' }
        Remove-Item -LiteralPath $checked -Recurse -Force
    }
}
