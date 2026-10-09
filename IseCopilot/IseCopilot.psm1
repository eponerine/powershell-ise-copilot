#Requires -Version 5.1
<#
    IseCopilot - a side-panel, multi-turn AI pair programmer for the PowerShell ISE,
    backed by Microsoft AI Foundry / Azure OpenAI chat completions.
#>

Set-StrictMode -Version 2.0

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:AddOnName  = 'Copilot for ISE'
$script:Fence      = '```'
$script:DefaultSystemMessage = 'You are GitHub Copilot, an expert PowerShell 5.1 infrastructure and automation assistant.'
$script:DefaultModels = @('gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo', 'o1', 'o3-mini', 'claude-3-5-sonnet')

$script:State = @{
    History      = New-Object System.Collections.Generic.List[object]
    LastResponse = $null
    Pending      = $null
    TopicId      = 0
}
$script:Ui    = @{}
$script:Pane  = $null
$script:Timer = $null
$script:RunspacePool = $null
$script:StartupSettings = @{}

#region Background request (runs in an isolated runspace - must be self-contained)
$script:RequestScript = {
    param([string]$Uri, [string]$Method, [string]$ApiKey, [string]$BodyJson, [string]$Kind)
    # Only plain .NET types go back to the UI thread; PSObjects from this runspace break the ISE engine there.
    $result = @{ Success = $false; Text = ''; Tokens = ''; Names = [string[]]@(); Error = '' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $params = @{
            Uri             = $Uri
            Method          = $Method
            Headers         = @{ 'api-key' = $ApiKey }
            ContentType     = 'application/json; charset=utf-8'
            TimeoutSec      = 300
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        if ($BodyJson) { $params.Body = [Text.Encoding]::UTF8.GetBytes($BodyJson) }

        $response = Invoke-WebRequest @params
        # Decode explicitly as UTF-8; PS 5.1 falls back to ISO-8859-1 when no charset is returned.
        $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
        $data = $text | ConvertFrom-Json

        if ($Kind -eq 'deployments') {
            $result.Names = [string[]]@($data.data | ForEach-Object { $_.id } | Where-Object { $_ } | Sort-Object -Unique)
        }
        else {
            $result.Text = [string]$data.choices[0].message.content
            if ($data.PSObject.Properties['usage'] -and $data.usage) { $result.Tokens = [string]$data.usage.total_tokens }
        }
        $result.Success = $true
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail += "`n" + $_.ErrorDetails.Message }
        $result.Error = [string]$detail
    }
    $result
}
#endregion

#region XAML
$script:Xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Width="350" HorizontalAlignment="Left" Background="White">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Copilot for ISE (AI Foundry)" FontSize="14" FontWeight="Bold" Margin="6,6,6,4"/>

    <Expander Grid.Row="1" x:Name="expSettings" Header="Settings" IsExpanded="False" Margin="6,0,6,4">
        <StackPanel Margin="4">
            <TextBlock Text="Foundry Endpoint / Resource URL"/>
            <TextBox x:Name="txtEndpoint" ToolTip="https://&lt;your-resource&gt;.openai.azure.com/"/>
            <TextBlock Text="API Key" Margin="0,4,0,0"/>
            <PasswordBox x:Name="pwdApiKey"/>
            <TextBlock Text="Deployment / Model" Margin="0,4,0,0"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ComboBox x:Name="cmbDeployment" Grid.Column="0" IsEditable="True"/>
                <Button x:Name="btnFetch" Grid.Column="1" Content="Fetch Deployments" Margin="4,0,0,0" Padding="4,0"/>
            </Grid>
            <TextBlock Text="API Version" Margin="0,4,0,0"/>
            <TextBox x:Name="txtApiVersion"/>
            <TextBlock Text="System Message" Margin="0,4,0,0"/>
            <TextBox x:Name="txtSystem" Height="60" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>
    </Expander>

    <RichTextBox Grid.Row="2" x:Name="rtbChat" IsReadOnly="True" IsReadOnlyCaretVisible="False"
                 VerticalScrollBarVisibility="Auto" Margin="6,0" Padding="2"/>

    <WrapPanel Grid.Row="3" Margin="6,4,6,4">
        <Button x:Name="btnExplain"  Content="Explain"           Margin="0,0,4,0" Padding="6,1" ToolTip="Explain the selected editor code"/>
        <Button x:Name="btnRefactor" Content="Refactor"          Margin="0,0,4,0" Padding="6,1" ToolTip="Find bugs and refactor the selected editor code"/>
        <Button x:Name="btnInsert"   Content="Insert Code"       Margin="0,0,4,0" Padding="6,1" ToolTip="Insert the suggested code block (or selected chat text) at the caret"/>
        <Button x:Name="btnReplace"  Content="Replace Selection" Padding="6,1" ToolTip="Replace the editor selection with the suggested code block (or selected chat text)"/>
    </WrapPanel>

    <TextBox Grid.Row="4" x:Name="txtPrompt" Height="70" AcceptsReturn="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" Margin="6,0"/>

    <StackPanel Grid.Row="5" Margin="6,4,6,6">
        <DockPanel LastChildFill="True">
            <Button x:Name="btnSend"     DockPanel.Dock="Left" Content="Send" Padding="12,2" FontWeight="Bold" ToolTip="Send (Ctrl+Enter)"/>
            <Button x:Name="btnNewTopic" DockPanel.Dock="Left" Content="New Topic" Padding="8,2" Margin="4,0,0,0"/>
            <TextBlock x:Name="txtStatus" Margin="6,0,0,0" VerticalAlignment="Center" Foreground="Gray" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <CheckBox x:Name="chkSelection"  Content="Attach Active Selection"   Margin="0,4,0,0"/>
        <CheckBox x:Name="chkFullScript" Content="Attach Full Script Context" Margin="0,2,0,0"/>
    </StackPanel>
</Grid>
'@
#endregion

#region Host control type
function Initialize-CopilotHostType {
    if ('IseCopilot.CopilotPane' -as [type]) { return }

    $refs = @(
        [Microsoft.PowerShell.Host.ISE.ObjectModelRoot].Assembly.Location
        [System.Windows.Controls.UserControl].Assembly.Location
        [System.Windows.UIElement].Assembly.Location
        [System.Windows.DependencyObject].Assembly.Location
        [System.Xaml.XamlReader].Assembly.Location
        [System.Management.Automation.Runspaces.Runspace].Assembly.Location
    )

    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System.Management.Automation.Runspaces;
using System.Windows.Controls;
using Microsoft.PowerShell.Host.ISE;

namespace IseCopilot
{
    public class CopilotPane : UserControl, IAddOnToolHostObject
    {
        public static Runspace HostRunspace;

        public CopilotPane()
        {
            // Script block event handlers need a runspace on the WPF UI thread.
            if (Runspace.DefaultRunspace == null && HostRunspace != null)
            {
                Runspace.DefaultRunspace = HostRunspace;
            }
        }

        public ObjectModelRoot HostObject { get; set; }
    }
}
'@
}
#endregion

#region UI helpers
function Invoke-Safely {
    param([scriptblock]$Action)
    # Unhandled exceptions on the WPF dispatcher would take down the ISE.
    try { & $Action }
    catch {
        Set-CopilotStatus ("Error: " + $_.Exception.Message)
        $detail = "{0}: {1}`n{2}`n{3}" -f $_.Exception.GetType().FullName, $_.Exception.Message,
            $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace
        try { Add-ChatEntry -Role 'Error' -Text $detail } catch { }
    }
}

function Set-CopilotStatus {
    param([string]$Text)
    if ($script:Ui.Count) { $script:Ui.txtStatus.Text = $Text; $script:Ui.txtStatus.ToolTip = $Text }
}

function Set-CopilotBusy {
    param([bool]$Busy, [string]$Text)
    foreach ($name in 'btnSend', 'btnExplain', 'btnRefactor', 'btnFetch') {
        $script:Ui[$name].IsEnabled = -not $Busy
    }
    Set-CopilotStatus $Text
}

function New-Brush {
    param([byte]$R, [byte]$G, [byte]$B)
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($R, $G, $B))
    $brush.Freeze()
    $brush
}

function Add-MarkdownInline {
    param($Inlines, [string]$Text)

    $pattern = '(?<code>`+)(?<codeText>[^`]+?)\k<code>|(?<bold>\*\*|__)(?<boldText>.+?)\k<bold>|(?<strike>~~)(?<strikeText>.+?)\k<strike>|(?<italicStar>\*)(?<italicStarText>[^*]+?)\k<italicStar>|(?<italicUnderscore>_)(?<italicUnderscoreText>[^_]+?)\k<italicUnderscore>'
    $position = 0
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        if ($match.Index -gt $position) {
            $Inlines.Add((New-Object System.Windows.Documents.Run $Text.Substring($position, $match.Index - $position)))
        }

        if ($match.Groups['code'].Success) {
            $run = New-Object System.Windows.Documents.Run $match.Groups['codeText'].Value
            $run.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
            $run.Background = New-Brush 0xF3 0xF3 0xF3
            $Inlines.Add($run)
        }
        else {
            $span = New-Object System.Windows.Documents.Span
            if ($match.Groups['bold'].Success) {
                $content = $match.Groups['boldText'].Value
                $span.FontWeight = [System.Windows.FontWeights]::Bold
            }
            elseif ($match.Groups['strike'].Success) {
                $content = $match.Groups['strikeText'].Value
                $span.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
            }
            elseif ($match.Groups['italicStar'].Success) {
                $content = $match.Groups['italicStarText'].Value
                $span.FontStyle = [System.Windows.FontStyles]::Italic
            }
            else {
                $content = $match.Groups['italicUnderscoreText'].Value
                $span.FontStyle = [System.Windows.FontStyles]::Italic
            }
            Add-MarkdownInline -Inlines $span.Inlines -Text $content
            $Inlines.Add($span)
        }
        $position = $match.Index + $match.Length
    }

    if ($position -lt $Text.Length) {
        $Inlines.Add((New-Object System.Windows.Documents.Run $Text.Substring($position)))
    }
}

function Add-MarkdownParagraph {
    param($Document, [string]$Text, [string]$Prefix = '', [int]$HeadingLevel = 0)

    $paragraph = New-Object System.Windows.Documents.Paragraph
    $paragraph.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
    if ($HeadingLevel -gt 0) {
        $paragraph.FontWeight = [System.Windows.FontWeights]::Bold
        $paragraph.FontSize = switch ($HeadingLevel) {
            1 { 20 }
            2 { 18 }
            3 { 16 }
            default { 14 }
        }
        $paragraph.Margin = New-Object System.Windows.Thickness 0, 6, 0, 4
    }
    if ($Prefix) { $paragraph.Inlines.Add((New-Object System.Windows.Documents.Run $Prefix)) }
    Add-MarkdownInline -Inlines $paragraph.Inlines -Text $Text
    $Document.Blocks.Add($paragraph)
}

function Add-ChatEntry {
    param([string]$Role, [string]$Text, [string]$Note)

    $doc = $script:Ui.rtbChat.Document
    $roleBrush = switch ($Role) {
        'User'    { New-Brush 0x1F 0x5F 0xAF }
        'Copilot' { New-Brush 0x6F 0x42 0xC1 }
        default   { New-Brush 0xC0 0x20 0x20 }
    }

    $header = New-Object System.Windows.Documents.Paragraph
    $header.Margin = New-Object System.Windows.Thickness 0, 8, 0, 2
    $roleRun = New-Object System.Windows.Documents.Run $Role
    $roleRun.FontWeight = [System.Windows.FontWeights]::Bold
    $roleRun.Foreground = $roleBrush
    $header.Inlines.Add($roleRun)
    if ($Note) {
        $noteRun = New-Object System.Windows.Documents.Run ("  " + $Note)
        $noteRun.FontStyle = [System.Windows.FontStyles]::Italic
        $noteRun.Foreground = [System.Windows.Media.Brushes]::Gray
        $header.Inlines.Add($noteRun)
    }
    $doc.Blocks.Add($header)

    $codeBackground = New-Brush 0xF3 0xF3 0xF3
    $pattern = '(?s)' + [regex]::Escape($script:Fence) + '[\w+.#-]*[ \t]*\r?\n(.*?)' + [regex]::Escape($script:Fence)
    $position = 0

    $addProse = {
        param([string]$Chunk)
        $paragraphLines = New-Object 'System.Collections.Generic.List[string]'
        $flushParagraph = {
            if ($paragraphLines.Count) {
                Add-MarkdownParagraph -Document $doc -Text ($paragraphLines -join ' ')
                $paragraphLines.Clear()
            }
        }

        foreach ($line in ($Chunk -split '\r?\n')) {
            if (-not $line.Trim()) { & $flushParagraph; continue }

            if ($line -match '^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$') {
                & $flushParagraph
                Add-MarkdownParagraph -Document $doc -Text $Matches[2] -HeadingLevel $Matches[1].Length
            }
            elseif ($line -match '^\s*[-+*]\s+(.+)$') {
                & $flushParagraph
                Add-MarkdownParagraph -Document $doc -Text $Matches[1] -Prefix ([string][char]0x2022 + ' ')
            }
            elseif ($line -match '^\s*(\d+)[.)]\s+(.+)$') {
                & $flushParagraph
                Add-MarkdownParagraph -Document $doc -Text $Matches[2] -Prefix ($Matches[1] + '. ')
            }
            else {
                $paragraphLines.Add($line.Trim())
            }
        }
        & $flushParagraph
    }

    foreach ($match in [regex]::Matches($Text, $pattern)) {
        & $addProse $Text.Substring($position, $match.Index - $position)
        $code = New-Object System.Windows.Documents.Paragraph (New-Object System.Windows.Documents.Run $match.Groups[1].Value.TrimEnd())
        $code.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
        $code.FontSize   = 12
        $code.Background = $codeBackground
        $code.Padding    = New-Object System.Windows.Thickness 4
        $code.Margin     = New-Object System.Windows.Thickness 0, 2, 0, 6
        $doc.Blocks.Add($code)
        $position = $match.Index + $match.Length
    }
    & $addProse $Text.Substring($position)

    $script:Ui.rtbChat.ScrollToEnd()
}
#endregion

#region ISE editor helpers
function Get-IseEditor {
    if ($psISE -and $psISE.CurrentFile) { return $psISE.CurrentFile.Editor }
    $null
}

function ConvertTo-CrLf {
    param([string]$Text)
    $Text -replace "`r?`n", "`r`n"
}

function Get-SuggestedCode {
    # An explicit selection in the chat pane wins over the auto-detected code block.
    $chatSelection = $script:Ui.rtbChat.Selection.Text
    if ($chatSelection -and $chatSelection.Trim()) { return ConvertTo-CrLf $chatSelection.Trim() }

    if (-not $script:State.LastResponse) { return $null }
    $pattern = '(?s)' + [regex]::Escape($script:Fence) + '([\w+.#-]*)[ \t]*\r?\n(.*?)' + [regex]::Escape($script:Fence)
    $blocks = @([regex]::Matches($script:State.LastResponse, $pattern))
    if (-not $blocks.Count) { return $null }

    $preferred = $blocks | Where-Object { $_.Groups[1].Value -match '^(powershell|posh|pwsh|ps1?|)$' } | Select-Object -First 1
    if (-not $preferred) { $preferred = $blocks[0] }
    ConvertTo-CrLf $preferred.Groups[2].Value.TrimEnd()
}

function Invoke-InsertAtCursor {
    $editor = Get-IseEditor
    if (-not $editor) { Set-CopilotStatus 'No active editor file.'; return }
    $code = Get-SuggestedCode
    if (-not $code) { Set-CopilotStatus 'No code block found in the last response.'; return }

    # Collapse any selection so InsertText inserts rather than replaces.
    $editor.SetCaretPosition($editor.CaretLine, $editor.CaretColumn)
    $editor.InsertText($code)
    Set-CopilotStatus 'Code inserted at cursor.'
}

function Invoke-ReplaceSelection {
    $editor = Get-IseEditor
    if (-not $editor) { Set-CopilotStatus 'No active editor file.'; return }
    if (-not $editor.SelectedText) { Set-CopilotStatus 'Select text in the editor first.'; return }
    $code = Get-SuggestedCode
    if (-not $code) { Set-CopilotStatus 'No code block found in the last response.'; return }

    $editor.InsertText($code)
    Set-CopilotStatus 'Selection replaced.'
}

function Invoke-SelectionAction {
    param([string]$Prompt)
    $editor = Get-IseEditor
    if (-not $editor -or -not $editor.SelectedText) { Set-CopilotStatus 'Select code in the editor first.'; return }
    Invoke-CopilotSend -Prompt $Prompt -Selection $editor.SelectedText
}
#endregion

#region Settings / requests
function Get-CopilotSettings {
    $rawEndpoint = $script:Ui.txtEndpoint.Text.Trim().TrimEnd('/')
    # Accept both the resource root and the newer ".../openai/v1" form shown in the Foundry portal.
    $useV1      = $rawEndpoint -match '/openai/v1$'
    $endpoint   = $rawEndpoint -replace '/openai(/v1)?$', ''
    $apiKey     = $script:Ui.pwdApiKey.Password
    $deployment = $script:Ui.cmbDeployment.Text.Trim()
    $apiVersion = $script:Ui.txtApiVersion.Text.Trim()

    $uri = $null
    if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        $script:Ui.expSettings.IsExpanded = $true
        Set-CopilotStatus 'Enter a valid https:// Foundry endpoint.'
        return $null
    }
    if (-not $apiKey) {
        $script:Ui.expSettings.IsExpanded = $true
        Set-CopilotStatus 'Enter an API key.'
        return $null
    }

    [pscustomobject]@{
        Endpoint   = $endpoint
        ApiKey     = $apiKey
        Deployment = $deployment
        ApiVersion = $apiVersion
        UseV1      = $useV1
    }
}

function Start-CopilotRequest {
    param(
        [string]$Uri,
        [string]$Method,
        [string]$ApiKey,
        [string]$BodyJson,
        [string]$Kind = 'chat',
        [scriptblock]$OnComplete,
        [string]$StatusText
    )

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    [void]$ps.AddScript($script:RequestScript.ToString()).AddArgument($Uri).AddArgument($Method).AddArgument($ApiKey).AddArgument($BodyJson).AddArgument($Kind)

    try {
        $script:State.Pending = @{
            PowerShell = $ps
            Handle     = $ps.BeginInvoke()
            OnComplete = $OnComplete
            TopicId    = $script:State.TopicId
        }
        Set-CopilotBusy $true $StatusText
        $script:Timer.Start()
    }
    catch {
        $script:State.Pending = $null
        $ps.Dispose()
        Set-CopilotBusy $false ''
        throw
    }
}

function Complete-CopilotRequest {
    $pending = $script:State.Pending
    if ($null -eq $pending -or -not $pending.Handle.IsCompleted) { return }

    $script:Timer.Stop()
    $script:State.Pending = $null
    Set-CopilotBusy $false ''

    # Keep this UI-thread code free of pipelines/cmdlets; only touch plain .NET objects.
    $result = $null
    $failure = 'The background request returned no result.'
    try {
        $output = $pending.PowerShell.EndInvoke($pending.Handle)
        if ($output.Count -gt 0) { $result = $output[$output.Count - 1].PSObject.BaseObject }
        foreach ($record in $pending.PowerShell.Streams.Error) { $failure += "`n" + $record.ToString() }
    }
    catch {
        $failure = $_.Exception.Message
    }
    $pending.PowerShell.Dispose()

    if ($result -isnot [hashtable]) {
        $result = @{ Success = $false; Text = ''; Tokens = ''; Names = [string[]]@(); Error = $failure }
    }

    # Discard responses that belong to a topic cleared with "New Topic".
    if ($pending.TopicId -ne $script:State.TopicId) { return }
    & $pending.OnComplete $result
}

function Invoke-CopilotSend {
    param([string]$Prompt, [string]$Selection)

    if ($script:State.Pending) { return }
    $fromPromptBox = -not $Prompt
    if ($fromPromptBox) { $Prompt = $script:Ui.txtPrompt.Text.Trim() }
    if (-not $Prompt) { return }

    $settings = Get-CopilotSettings
    if (-not $settings) { return }

    $editor   = Get-IseEditor
    $fileName = if ($psISE -and $psISE.CurrentFile) { $psISE.CurrentFile.DisplayName } else { 'Untitled' }
    $fence    = $script:Fence
    $content  = $Prompt
    $notes    = @()

    if (-not $Selection -and $script:Ui.chkSelection.IsChecked -and $editor -and $editor.SelectedText) {
        $Selection = $editor.SelectedText
    }
    if ($Selection) {
        $content += "`n`nSelected code from '$fileName':`n${fence}powershell`n$Selection`n$fence"
        $notes += 'selection'
    }
    if ($script:Ui.chkFullScript.IsChecked -and $editor -and $editor.Text) {
        $content += "`n`nFull script '$fileName' for context:`n${fence}powershell`n$($editor.Text)`n$fence"
        $notes += 'full script'
    }

    $script:State.History.Add([ordered]@{ role = 'user'; content = $content })
    $note = if ($notes) { '[+ ' + ($notes -join ', ') + ']' } else { $null }
    Add-ChatEntry -Role 'User' -Text $Prompt -Note $note
    if ($fromPromptBox) { $script:Ui.txtPrompt.Clear() }

    $messages = @([ordered]@{ role = 'system'; content = $script:Ui.txtSystem.Text }) + $script:State.History.ToArray()
    $body = [ordered]@{ messages = $messages }
    # Reasoning models (o-series, gpt-5+) reject a custom temperature.
    if ($settings.Deployment -notmatch '^(o\d|gpt-([5-9]|\d\d))') { $body.temperature = 0.2 }

    if ($settings.UseV1) {
        $body.model = $settings.Deployment
        $uri = '{0}/openai/v1/chat/completions' -f $settings.Endpoint
    }
    else {
        $uri = '{0}/openai/deployments/{1}/chat/completions?api-version={2}' -f $settings.Endpoint,
            [Uri]::EscapeDataString($settings.Deployment), [Uri]::EscapeDataString($settings.ApiVersion)
    }
    $json = $body | ConvertTo-Json -Depth 6 -Compress

    Start-CopilotRequest -Uri $uri -Method 'POST' -ApiKey $settings.ApiKey -BodyJson $json -StatusText 'Copilot is thinking...' -OnComplete {
        param($Result)
        if ($Result.Success) {
            $text = [string]$Result.Text
            if (-not $text) { $text = '(empty response)' }
            $script:State.History.Add([ordered]@{ role = 'assistant'; content = $text })
            $script:State.LastResponse = $text
            Add-ChatEntry -Role 'Copilot' -Text $text
            if ($Result.Tokens) { Set-CopilotStatus ("{0} tokens" -f $Result.Tokens) }
        }
        else {
            # Drop the failed user turn so the history stays consistent for a retry.
            $history = $script:State.History
            if ($history.Count -and $history[$history.Count - 1].role -eq 'user') { $history.RemoveAt($history.Count - 1) }
            Add-ChatEntry -Role 'Error' -Text $Result.Error
            Set-CopilotStatus 'Request failed.'
        }
    }
}

function Invoke-FetchDeployments {
    if ($script:State.Pending) { return }
    $settings = Get-CopilotSettings
    if (-not $settings) { return }

    # Deployment listing is only exposed by the 2022-12-01 data-plane API version.
    $uri = '{0}/openai/deployments?api-version=2022-12-01' -f $settings.Endpoint
    Start-CopilotRequest -Uri $uri -Method 'GET' -ApiKey $settings.ApiKey -Kind 'deployments' -StatusText 'Fetching deployments...' -OnComplete {
        param($Result)
        if (-not $Result.Success) {
            Add-ChatEntry -Role 'Error' -Text ("Fetch Deployments failed:`n" + $Result.Error)
            Set-CopilotStatus 'Fetch failed.'
            return
        }
        $names = [string[]]$Result.Names
        if (-not $names.Count) { Set-CopilotStatus 'No deployments found.'; return }

        $combo = $script:Ui.cmbDeployment
        $current = $combo.Text
        $combo.Items.Clear()
        foreach ($name in $names) { [void]$combo.Items.Add($name) }
        $combo.Text = if ($current -and $names -contains $current) { $current } else { $names[0] }
        Set-CopilotStatus ("Found {0} deployment(s)." -f $names.Count)
    }
}

function Clear-CopilotTopic {
    $script:State.TopicId++
    $script:State.History.Clear()
    $script:State.LastResponse = $null
    $script:Ui.rtbChat.Document.Blocks.Clear()
    if ($script:State.Pending) { Set-CopilotStatus 'New topic (pending reply will be discarded).' }
    else { Set-CopilotStatus 'New topic started.' }
}
#endregion

#region UI construction (runs on the WPF UI thread)
function Initialize-CopilotUi {
    $root = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
    $names = 'expSettings', 'txtEndpoint', 'pwdApiKey', 'cmbDeployment', 'btnFetch', 'txtApiVersion', 'txtSystem',
             'rtbChat', 'btnExplain', 'btnRefactor', 'btnInsert', 'btnReplace', 'txtPrompt', 'btnSend',
             'btnNewTopic', 'txtStatus', 'chkSelection', 'chkFullScript'
    foreach ($name in $names) { $script:Ui[$name] = $root.FindName($name) }

    $s = $script:StartupSettings
    $script:Ui.txtEndpoint.Text   = $s.Endpoint
    $script:Ui.txtApiVersion.Text = $s.ApiVersion
    $script:Ui.txtSystem.Text     = $script:DefaultSystemMessage
    if ($s.ApiKey) { $script:Ui.pwdApiKey.Password = $s.ApiKey }
    foreach ($model in $script:DefaultModels) { [void]$script:Ui.cmbDeployment.Items.Add($model) }
    $script:Ui.cmbDeployment.Text = $s.Deployment
    if (-not $s.Endpoint -or -not $s.ApiKey) { $script:Ui.expSettings.IsExpanded = $true }

    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = New-Object System.Windows.Thickness 2
    $doc.FontFamily  = New-Object System.Windows.Media.FontFamily 'Segoe UI'
    $doc.FontSize    = 12
    $script:Ui.rtbChat.Document = $doc

    $script:Ui.btnSend.Add_Click({ Invoke-Safely { Invoke-CopilotSend } })
    $script:Ui.btnNewTopic.Add_Click({ Invoke-Safely { Clear-CopilotTopic } })
    $script:Ui.btnFetch.Add_Click({ Invoke-Safely { Invoke-FetchDeployments } })
    $script:Ui.btnInsert.Add_Click({ Invoke-Safely { Invoke-InsertAtCursor } })
    $script:Ui.btnReplace.Add_Click({ Invoke-Safely { Invoke-ReplaceSelection } })
    $script:Ui.btnExplain.Add_Click({
        Invoke-Safely { Invoke-SelectionAction 'Explain what this PowerShell code does step-by-step.' }
    })
    $script:Ui.btnRefactor.Add_Click({
        Invoke-Safely { Invoke-SelectionAction 'Identify bugs and refactor this PowerShell code for performance and best practices.' }
    })
    $script:Ui.txtPrompt.Add_PreviewKeyDown({
        param($source, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
                $e.Handled = $true
                Invoke-Safely { Invoke-CopilotSend }
            }
            else {
                $e.Handled = $true
                $source.SelectedText = "`r`n"
                $source.CaretIndex += 2
            }
        }
    })

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:Timer.Add_Tick({ Invoke-Safely { Complete-CopilotRequest } })

    $script:Pane.Content = $root
}
#endregion

#region Public commands
function Start-IseCopilot {
    <#
    .SYNOPSIS
        Opens the Copilot for ISE side panel.
    .EXAMPLE
        Start-IseCopilot -Endpoint 'https://contoso.openai.azure.com/' -Deployment 'gpt-4o'
    #>
    [CmdletBinding()]
    param(
        [string]$Endpoint   = $(if ($env:AZURE_AI_FOUNDRY_ENDPOINT) { $env:AZURE_AI_FOUNDRY_ENDPOINT } else { $env:AZURE_OPENAI_ENDPOINT }),
        [string]$Deployment = $(if ($env:AZURE_OPENAI_DEPLOYMENT) { $env:AZURE_OPENAI_DEPLOYMENT } else { 'gpt-4o' }),
        [string]$ApiVersion = '2024-10-21'
    )

    if (-not (Get-Variable -Name psISE -Scope Global -ErrorAction SilentlyContinue)) {
        throw 'Start-IseCopilot must be run inside the PowerShell ISE.'
    }

    $tools = $psISE.CurrentPowerShellTab.VerticalAddOnTools
    $existing = $tools | Where-Object { $_.Name -eq $script:AddOnName }
    if ($existing) {
        $existing.IsVisible = $true
        return
    }

    Initialize-CopilotHostType
    [IseCopilot.CopilotPane]::HostRunspace = [runspace]::DefaultRunspace

    $script:StartupSettings = @{
        Endpoint   = $Endpoint
        Deployment = $Deployment
        ApiVersion = $ApiVersion
        ApiKey     = $(if ($env:AZURE_AI_FOUNDRY_KEY) { $env:AZURE_AI_FOUNDRY_KEY } else { $env:AZURE_OPENAI_KEY })
    }

    # Opened here (pipeline thread) so the WPF UI thread never has to open a runspace.
    if (-not $script:RunspacePool) {
        $script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, 2)
        $script:RunspacePool.Open()
    }

    $addOn = $tools.Add($script:AddOnName, [IseCopilot.CopilotPane], $true)
    $script:Pane = $addOn.Control
    $script:Pane.Dispatcher.Invoke([Action] { Initialize-CopilotUi })
}

function Stop-IseCopilot {
    <#
    .SYNOPSIS
        Closes the Copilot for ISE side panel and clears the conversation.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Variable -Name psISE -Scope Global -ErrorAction SilentlyContinue)) { return }
    $tools = $psISE.CurrentPowerShellTab.VerticalAddOnTools
    $existing = $tools | Where-Object { $_.Name -eq $script:AddOnName }
    if ($existing) { [void]$tools.Remove($existing) }

    if ($script:Timer) { $script:Timer.Stop() }
    if ($script:State.Pending) {
        $script:State.Pending.PowerShell.Dispose()
        $script:State.Pending = $null
    }
    if ($script:RunspacePool) {
        $script:RunspacePool.Dispose()
        $script:RunspacePool = $null
    }
    $script:State.History.Clear()
    $script:State.LastResponse = $null
    $script:Ui = @{}
    $script:Pane = $null
}
#endregion

Export-ModuleMember -Function Start-IseCopilot, Stop-IseCopilot
