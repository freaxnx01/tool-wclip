#requires -Version 7
# Clipboard helpers for the wclip receiver. Kept separate from the listener so the
# CF_HTML encoding can be tested without a running HTTP server or a clipboard.

Set-StrictMode -Version Latest

function ConvertTo-CfHtml {
    <#
    .SYNOPSIS
        Wraps HTML in the CF_HTML clipboard envelope (header with byte offsets + fragment markers).
    .DESCRIPTION
        Windows' "HTML Format" clipboard type needs a header that gives the byte offsets of the
        whole HTML and of the fragment to paste. WinForms writes the string as UTF-8, so the
        offsets are counted in UTF-8 bytes, not characters. A full document (one with <body>)
        keeps its <head> (Outlook honours its <style>) and gets the fragment markers inside
        <body>; anything else is wrapped in a minimal document.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $start = '<!--StartFragment-->'
    $end = '<!--EndFragment-->'

    $bodyOpen = [regex]::Match($Html, '<body\b[^>]*>', 'IgnoreCase')
    $bodyClose = [regex]::Match($Html, '</body\s*>', 'IgnoreCase,RightToLeft')
    if ($bodyOpen.Success -and $bodyClose.Success -and $bodyClose.Index -ge ($bodyOpen.Index + $bodyOpen.Length)) {
        $before = $Html.Substring(0, $bodyOpen.Index + $bodyOpen.Length)
        $fragment = $Html.Substring($before.Length, $bodyClose.Index - $before.Length)
        $after = $Html.Substring($bodyClose.Index)
    } else {
        $before = '<html><head><meta charset="utf-8"></head><body>'
        $fragment = $Html
        $after = '</body></html>'
    }
    $document = "$before$start$fragment$end$after"

    # Fixed-width (10 digit) offsets so the header length does not depend on the values.
    $template = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
    $headerLength = $utf8.GetByteCount(($template -f 0, 0, 0, 0))

    $startHtml = $headerLength
    $startFragment = $startHtml + $utf8.GetByteCount("$before$start")
    $endFragment = $startFragment + $utf8.GetByteCount($fragment)
    $endHtml = $startHtml + $utf8.GetByteCount($document)

    ($template -f $startHtml, $endHtml, $startFragment, $endFragment) + $document
}

function ConvertTo-PlainText {
    <#
    .SYNOPSIS
        Crude HTML → text for the plain-text clipboard fallback (Notepad, terminals).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)

    $text = [regex]::Replace($Html, '(?is)<(head|style|script)\b.*?</\1\s*>', '')
    $text = [regex]::Replace($text, '(?i)<br\s*/?>', "`n")
    $text = [regex]::Replace($text, '(?i)</(p|h[1-6])\s*>', "`n`n")
    $text = [regex]::Replace($text, '(?i)</(div|li|tr)\s*>', "`n")
    $text = [regex]::Replace($text, '<[^>]+>', '')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, "[ \t]+`n", "`n")
    [regex]::Replace($text, "`n{3,}", "`n`n").Trim()
}

function Set-WclipClipboard {
    <#
    .SYNOPSIS
        Puts text, or HTML plus a plain-text fallback, on the Windows clipboard.
    .NOTES
        Needs an STA thread (pwsh's default) in an interactive session.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [ValidateSet('text', 'html')][string]$Format = 'text'
    )

    Add-Type -AssemblyName System.Windows.Forms
    $data = [System.Windows.Forms.DataObject]::new()
    if ($Format -eq 'html') {
        $data.SetData([System.Windows.Forms.DataFormats]::Html, (ConvertTo-CfHtml $Content))
        $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, (ConvertTo-PlainText $Content))
    } else {
        $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Content)
    }
    # copy=$true keeps the data after this process exits; retry while another app holds the clipboard.
    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
}

Export-ModuleMember -Function ConvertTo-CfHtml, ConvertTo-PlainText, Set-WclipClipboard
