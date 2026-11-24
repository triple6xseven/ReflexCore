# Isolated local Windows Forms test fixture. The guarded demo may supply an owned output.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if ($env:REFLEXCORE_FIXTURE_BACKGROUND -ceq '1') {
    Add-Type -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll -TypeDefinition @"
using System.Windows.Forms;
public sealed class ReflexNoActivateFixture : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
            return parameters;
        }
    }
}
"@
    $form = New-Object ReflexNoActivateFixture
    $form.ShowInTaskbar = $false
    $form.Opacity = 0
} else {
    $form = New-Object System.Windows.Forms.Form
}
$form.Text = 'ReflexCore Test Window'
$form.Name = 'RcFixture'
$form.Width = 520
$form.Height = 240
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = 'Input:'
$label.Left = 20
$label.Top = 24
$label.AutoSize = $true

# Store controls in script scope: event callbacks execute in a new scope.
# Never use $input here: it is a PowerShell automatic variable.
$script:RcInputBox = New-Object System.Windows.Forms.TextBox
$script:RcInputBox.Name = 'RcInput'
$script:RcInputBox.AccessibleName = 'ReflexCore Input'
$script:RcInputBox.Left = 105
$script:RcInputBox.Top = 20
$script:RcInputBox.Width = 350

$apply = New-Object System.Windows.Forms.Button
$apply.Name = 'RcApply'
$apply.Text = 'Apply'
$apply.AccessibleName = 'Apply'
$apply.Left = 105
$apply.Top = 68
$apply.Width = 140

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Output:'
$outputLabel.Left = 20
$outputLabel.Top = 125
$outputLabel.AutoSize = $true

$script:RcOutputBox = New-Object System.Windows.Forms.TextBox
$script:RcOutputBox.Name = 'RcOutput'
$script:RcOutputBox.AccessibleName = 'ReflexCore Output'
$script:RcOutputBox.Left = 105
$script:RcOutputBox.Top = 122
$script:RcOutputBox.Width = 350
$script:RcOutputBox.ReadOnly = $true

# Explicit script-scoped references survive the WinForms Click event scope.
$apply.Add_Click({
    if ($env:REFLEXCORE_FIXTURE_SAVE_PATH) {
        $file = [IO.File]::Open($env:REFLEXCORE_FIXTURE_SAVE_PATH, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($script:RcInputBox.Text)
            $file.Write($bytes, 0, $bytes.Length)
        } finally { $file.Dispose() }
    }
    $script:RcOutputBox.Text = $script:RcInputBox.Text
})
$form.Controls.AddRange(@(
    $label, $script:RcInputBox, $apply, $outputLabel, $script:RcOutputBox
))
[System.Windows.Forms.Application]::Run($form)
