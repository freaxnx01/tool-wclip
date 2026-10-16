#requires -Version 7
# Dependency-free checks for the CF_HTML envelope: run `pwsh -NoProfile -File tests/Wclip.Tests.ps1`.
# Exits non-zero on the first failure.

Import-Module (Join-Path $PSScriptRoot '..\windows\Wclip.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)
$failed = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name"; $script:failed++ }
}

function Get-Offsets([string]$CfHtml) {
    $o = @{}
    foreach ($k in 'StartHTML', 'EndHTML', 'StartFragment', 'EndFragment') {
        $o[$k] = [int]([regex]::Match($CfHtml, "$k`:(\d+)").Groups[1].Value)
    }
    $o
}

function Test-Envelope([string]$Name, [string]$Html, [string]$ExpectedFragment) {
    $cf = ConvertTo-CfHtml $Html
    $bytes = $utf8.GetBytes($cf)
    $o = Get-Offsets $cf
    $fragment = $utf8.GetString($bytes, $o.StartFragment, $o.EndFragment - $o.StartFragment)
    $document = $utf8.GetString($bytes, $o.StartHTML, $o.EndHTML - $o.StartHTML)
    Assert-True ($fragment -ceq $ExpectedFragment) "$Name — fragment offsets cut exactly the fragment"
    Assert-True ($o.EndHTML -eq $bytes.Length) "$Name — EndHTML is the end of the data"
    Assert-True ($document.StartsWith('<')) "$Name — StartHTML points at markup"
    Assert-True ($utf8.GetString($bytes, $o.StartFragment - 20, 20) -ceq '<!--StartFragment-->') "$Name — StartFragment follows its marker"
}

Test-Envelope 'bare fragment' '<p>Hoi <b>Martin</b></p>' '<p>Hoi <b>Martin</b></p>'
Test-Envelope 'non-ASCII counted in bytes' '<p>Grüsse – Andreas ✓</p>' '<p>Grüsse – Andreas ✓</p>'
Test-Envelope 'full document keeps head' `
    '<html><head><style>p{color:red}</style></head><body class="x"><p>Hä?</p></body></html>' '<p>Hä?</p>'

$cf = ConvertTo-CfHtml '<html><head><style>p{}</style></head><body><p>x</p></body></html>'
Assert-True ($cf -match '<head><style>p\{\}</style></head><body><!--StartFragment-->') 'full document — markers inside body, head untouched'

$text = ConvertTo-PlainText '<html><head><style>p{color:red}</style></head><body><p>Hoi &bdquo;Du&ldquo;</p><p>a<br>b</p></body></html>'
# „ and “ are string delimiters to PowerShell, so they are built from code points.
Assert-True ($text -ceq ('Hoi {0}Du{1}' -f [char]0x201E, [char]0x201C) + "`n`na`nb") "plain-text fallback drops head, decodes entities, keeps breaks (got: $($text -replace "`n",'\n'))"

if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
