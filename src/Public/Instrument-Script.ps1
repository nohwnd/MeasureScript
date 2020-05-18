using namespace System.Management.Automation.Language
using namespace System.Collections.Generic
using namespace System.Diagnostics

Function Instrument-Script {
    [CmdletBinding(DefaultParameterSetName="ScriptBlock")]
    param(
        [Parameter(Mandatory=$true,ParameterSetName="ScriptBlock",Position=0)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$true,ParameterSetName="Path",Position=0)]
        [string]$Path,
        [Parameter(Mandatory=$false,ParameterSetName="__AllParametersets")]
        [string]$ExecutionResultVariable,
        [Parameter(Mandatory=$false,ParameterSetName="__AllParametersets")]
        [hashtable]$Arguments,
        [Parameter(Mandatory=$false,ParameterSetName="__AllParametersets")]
        [string]$Name
    )


    if($PSCmdlet.ParameterSetName -eq "Path") {
        if(-not (Test-Path $Path)) {
            throw "No such file: '$Path'"
        }
        $ScriptText = Get-Content $Path -Raw
        $ScriptBlock = [scriptblock]::Create($ScriptText)
        $Source = $Path
    }
    else {
        $Source = '{{{0}}}' -f (New-Guid)
        $Source = $Source -replace '-'

        $ssiPropertyInfo = [scriptblock].GetProperty('SessionStateInternal', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $callerSessionState = $ssiPropertyInfo.GetValue($ScriptBlock)
    }

    if($PSBoundParameters.Keys -icontains "Name"){
        $Source = "{0}: {1}$Name" -f $Source,$([System.Environment]::NewLine) 
    }

    $profiler = [Profiler]::new($ScriptBlock.Ast.Extent)
    $visitor  = [ProfilingAstVisitor]::new($profiler)
    $newAst   = $ScriptBlock.Ast.Visit($visitor)


    $MeasureScriptblock = $newAst.GetScriptBlock()

    if($PSCmdlet.ParameterSetName -eq "ScriptBlock"){
        $ssiPropertyInfo.SetValue($MeasureScriptblock, $callerSessionState)
        return [PSCustomObject]@{
            Profiler = $profiler
            ScriptBlock = $ScriptBlock
        }
    }

    if($PSCmdlet.ParameterSetName -eq "Path"){
        $MeasureScriptblock.Ast.Extent | Set-Content -Path $Path
        return [PSCustomObject]@{
            Profiler = $profiler
            Path = $Path
        }
    }

    # if($PSBoundParameters.Keys -icontains "Name"){
    #     $Source = "{0}: {1}$Name" -f $Source,$([System.Environment]::NewLine) 
    # }


    # if(-not $PSBoundParameters.ContainsKey('ExecutionResultVariable')){
    #     $null = & $MeasureScriptblock @Arguments
    # }
    # else {
    #     $executionResult = . $MeasureScriptblock @Arguments
    # }

    # [string[]]$lines = $ScriptBlock.ToString() -split '\r?\n' |ForEach-Object TrimEnd
    # for($i = 0; $i -lt $lines.Count;$i++){
    #     [pscustomobject]@{
    #         LineNo        = $i + 1
    #         ExecutionTime = $profiler.TimeLines[$i].GetTotal()
    #         TimeLine      = $profiler.TimeLines[$i]
    #         Line          = $lines[$i]
    #         SourceScript  = $Source
    #         PSTypeName    = 'ScriptLineMeasurement'
    #     }
    # }

    # if($ExecutionResultVariable) {
    #     try{
    #         $PSCmdlet.SessionState.PSVariable.Set($ExecutionResultVariable, $executionResult)
    #     }
    #     catch{
    #         Write-Error -Message "Error encountered setting ExecutionResultVariable '`${$ExecutionResultVariable}'" -Exception $_
    #     }
    # }
}

