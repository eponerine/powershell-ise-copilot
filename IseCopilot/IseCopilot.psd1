@{
    RootModule        = 'IseCopilot.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3b7f6c1e-9a52-4d8e-b0f4-6e2a1c9d7f30'
    Author            = 'Ernie Costa'
    Description       = 'Side-panel, multi-turn AI pair programmer for the PowerShell ISE using Microsoft AI Foundry / Azure OpenAI.'
    PowerShellVersion = '5.1'
    PowerShellHostName = 'Windows PowerShell ISE Host'
    FunctionsToExport = @('Start-IseCopilot', 'Stop-IseCopilot')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
