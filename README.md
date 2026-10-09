# powershell-ise-copilot
A ridiculous experiment in heritage software.

<img width="1000" height="550" alt="image" src="https://github.com/user-attachments/assets/d43aa9e4-3f11-47d7-b820-9a82a7d1e03d" />


## WTF is this?

A Copilot-style AI chat panel for the **Windows PowerShell ISE**: an editor that Microsoft stopped adding features to years ago and that only runs PowerShell 5.1 on .NET Framework.

It docks into the ISE add-on pane, sends multi-turn chats to Microsoft AI Foundry / Azure OpenAI, and can explain, refactor, insert or replace code in your editor. It's one `.psm1` file made of WPF XAML, some C# compiled on the fly with `Add-Type`, and background runspaces.

## Should you use this?

No. Seriously.

- **VS Code** with the PowerShell extension and **GitHub Copilot** already does all of this, and much better: inline completions, agent mode, PowerShell 7, a real debugger, and an extension that is still maintained.
- The ISE runs WPF event handlers on its UI thread using a runspace that belongs to someone else. Getting this to work at all involved dodging `NullReferenceException`s that came out of the PowerShell engine itself.
- There's no streaming, no inline ghost text, no tokenizer and no settings persistence. Your API key lives in an environment variable or a `PasswordBox`.
- If you run a long script while the panel is busy, things may get weird. That's the ISE, not you.

## But...

If you love crufty old things (if you still have `powershell_ise.exe` pinned to your taskbar, if you miss the blue console pane, if you have a locked-down server where the ISE is the only editor allowed), then this is for you. Have fun.

## Usage (Windows PowerShell ISE 5.1)

```powershell
$env:AZURE_AI_FOUNDRY_KEY = '<key>'   # or $env:AZURE_OPENAI_KEY
Import-Module .\IseCopilot\IseCopilot.psd1
Start-IseCopilot -Endpoint 'https://<your-resource>.openai.azure.com/' -Deployment 'gpt-4o'
```

- **Send**: button or `Ctrl+Enter`. **New Topic** clears the conversation history.
- **Explain / Refactor**: send the current editor selection with a canned prompt.
- **Insert Code / Replace Selection**: use the first PowerShell code block from the last reply, or any text you select in the chat pane.
- `Stop-IseCopilot` removes the panel.
- The endpoint can be the resource root or the `.../openai/v1` URL from the Foundry portal.
