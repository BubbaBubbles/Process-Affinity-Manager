# Version check
if (!([version]$PSVersionTable.PSVersion -ge [version]'7.0.0')) {
  Write-Warning "This script REQUIRES features enabled by Powershell v7 or later"
  Write-Host "Install Powershell v7 by running 'winget install Microsoft.Powershell' in your local powershell"
  Start-Sleep -Seconds 10
  throw "Powershell needs to be version 7 or greater to run this script"
}

# Lets collect some system info
[int]$script:totalCores = ([System.Environment]::ProcessorCount | Out-String).Trim()
$is64Bit = [System.Environment]::Is64BitOperatingSystem
$areWeAdmin = [System.Environment]::IsPrivilegedProcess
[System.GC]::Collect()

# Disclaimers and checks
if (!$is64Bit) {
  throw "System isn't 64-bit. If you are on a 32-bit system, upgrade. If you are on something else, idk how to help you"
}
if ($script:totalCores -gt 64) {
  throw "This script doesn't support processor groups right now"
}
if (!$areWeAdmin) {
  Write-Warning "Script is not elevated, this will prevent changing affinities on more sensitive processes i.e. steam parent process"
} else {
  Write-Host "Script is running with elevation" -ForegroundColor Magenta -BackgroundColor Black
}

# Lets make reading the affinity value of a process readable by a human
$threadsList = New-Object System.Collections.Generic.List[System.Object]
for ($i = 0; $i -lt $script:totalCores; $i++) {
  [string] $step1 = ('1' + ('0' * $i)).Trim()
  [string] $step2 = '0b' + (($step1 | Out-String).PadLeft(64, '0'))
  $threadsList.Add("Core$i = $step2")
}
$threadsList.ToArray() | Out-Null
Invoke-Expression "[flags()] enum readableCore : long {$($threadsList -join "`n")}"

# This will be default process detections that we throw on the screen when the script is ran
# https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions?view=powershell-7.4
# https://learn.microsoft.com/en-us/dotnet/standard/base-types/regular-expression-language-quick-reference
$defaultDet = Get-Process | Where-Object {
  $_.Path -match '^E:\\.*'
} -ErrorAction SilentlyContinue
$defaultDetReadableCore = {
  foreach ($item in $defaultDet) {
    [readableCore][long]$item.ProcessorAffinity
  }
}

# Lets make some functions for user interactability
function Get-UserSelectValues {
  param(
    [Parameter(Mandatory)]
    [ValidateScript(
      {
        $_ | ForEach-Object {
          (($_ -match '^[0-9]+$') -or ($_ -match '^[0-9]+-[0-9]+$'))
        }
      }
    )]
    $userSelectArray
  )
  $selectList = New-Object System.Collections.Generic.List[System.Object]
  switch -Regex ($userSelectArray) {
    '^[0-9]+$' {
      $selectList.Add($_) ; continue
    }
    '^[0-9]+-[0-9]+$' {
      $range = $_.split("-") | ForEach-Object { [int]$_ }
      $range  = $range[0]..$range[1]
      $range | ForEach-Object {
        $selectList.Add($_)
      }
    }
  }
  $selectList = $selectList | Sort-Object | Get-Unique
  foreach ($item in $selectList) {
    if (($item -ge $script:totalCores) -or ($item -lt 0)) {
      throw "Input is larger than the amount of cores available on the system, input cannot be negative"
    }
    [string] $step1 = ('1' + ('0' * $item)).Trim()
    [string] $step2 = '0b' + (($step1 | Out-String).PadLeft(64, '0'))
    $selectAffinityValue = [long]$selectAffinityValue + [long]$step2
  }
  return $selectAffinityValue
}

function Get-UserInput {
  try {
    Write-Host "Input: " -ForegroundColor DarkCyan -BackgroundColor Black -NoNewline
    [string] $userInput = Read-Host
    if (!($userInput -match '.+')) {
      throw "Empty inputs are forbidden"
    }
    return $userInput.Trim()
  } catch {
    Write-Error $_.Exception.Message
    Get-UserInput
  }
}

function Get-ManualProcess {
  param(
    [ValidateScript(
      {($_ -match '.+')}
    )]
    [string] $find
  )

  if ($find) {
    $search = $find
  } else {
    Write-Host " "
    Write-Host "Type in the name of the process you would like to change affinities for:" -ForegroundColor DarkGreen -BackgroundColor Black
    $search = Get-UserInput
  }
  try {
    $findings = Get-Process | Where-Object {
      $_.Name -match "^$($search).*"
    }
    if (!$findings) {
      Write-Warning "Did not find any processes with the query '$($search)'"
      Write-Warning "Resetting..."
      Write-Host " "
      Start-Sleep -Seconds 1
      Get-InitialInput
      exit
    }
    Write-Host " "
    Write-Host "Detected process(es):"
    Write-Host "$($findings | Out-String)"
    $detection = {
      foreach ($item in $findings) {
        [readableCore][long]$item.ProcessorAffinity
      }
    }
    Invoke-Command -ScriptBlock $detection
    Write-Host " "
    Write-Host "To change affinity, type in the cpu threads you would like the process(es) to be put on" -ForegroundColor DarkGreen -BackgroundColor Black
    Write-Host "You may type a comma seperated list, and include ranges with dashes, i.e. '0,10-15,31' (hint, they start at 0)" -ForegroundColor DarkGreen -BackgroundColor Black
    $userSelection = Get-UserInput
    $userSelectArray = $userSelection -split ","
    $affinityValue = Get-UserSelectValues -userSelectArray $userSelectArray
    Set-ProcessAffinity -derivedAffinity $affinityValue -process $findings
  } catch {
    Write-Warning "Cannot find specified process/error occurred"
    Write-Error $_.Exception.Message
    Start-Sleep -Seconds 3
    Get-InitialInput
  }
}

function Set-ProcessAffinity {
  param(
    [Parameter(Mandatory)]
    $derivedAffinity,
    [Parameter(Mandatory)]
    $process
  )

  $detectedAffinity = {
    foreach ($item in $process) {
      [readableCore][long]$item.ProcessorAffinity
    }
  }
  Write-Host " "
  Write-Host "Original:" -ForegroundColor Magenta -BackgroundColor Black
  Write-Host "$($process | Out-String)"
  Invoke-Command -ScriptBlock $detectedAffinity
  
  try {
    foreach ($item in $process) {
      [long]$item.ProcessorAffinity = [long]$derivedAffinity
    }
    Write-Host " "
    Write-Host " "
    Write-Host "New:" -ForegroundColor Magenta -BackgroundColor Black
    Write-Host "$($process | Out-String)"
    Invoke-Command -ScriptBlock $detectedAffinity
  } catch {
    Write-Warning "An error occurred"
    Write-Error $_.Exception.Message
    Start-Sleep -Seconds 3
    Get-InitialInput
  }
  exit
}

function Get-InitialInput {
  Write-Host "Total threads detected - $($script:totalCores)" -ForegroundColor Magenta -BackgroundColor Black
  Write-Host "Below are the processes that are running in the default path, and their CPU affinities:"
  if (!$defaultDet) {
    Write-Warning "No processes detected that match the default capture list, unedited default path is '^E:\\.*'"
  }
  Write-Host ($($defaultDet) | Out-String)
  Invoke-Command -ScriptBlock $defaultDetReadableCore
  Write-Host " "
  Write-Host " "
  Write-Host "You can now change the affinity of the detected processes, or manually specify a process to match by name"
  Write-Host "To change affinity, type in the cpu threads you would like the process(es) to be put on" -ForegroundColor DarkGreen -BackgroundColor Black
  Write-Host "You may type a comma seperated list, and include ranges with dashes, i.e. '0,10-15,31' (hint, they start at 0)" -ForegroundColor DarkGreen -BackgroundColor Black
  Write-Host "To manually specify a process to match by name, type 'manual'" -ForegroundColor DarkGreen -BackgroundColor Black
  Write-Host "To cancel, type exit" -ForegroundColor DarkGreen -BackgroundColor Black
  $initialInput = Get-UserInput
  switch ($initialInput) {
    { $_ -eq 'exit' } {
      Write-Output "User requested exit, exitting"
      exit 
    }
    { $_ -eq 'manual' } {
      Get-ManualProcess
      exit
    }
    { ($_ -notmatch '[^0-9,-]') -and ($defaultDet) } {
      try {
        $userSelectArray = $_ -split ","
        $affinityValue = Get-UserSelectValues -userSelectArray $userSelectArray
        Set-ProcessAffinity -process $defaultDet -derivedAffinity $affinityValue
        exit
      } catch {
        Write-Error $_.Exception.Message
        Get-InitialInput
        exit
      }
    }
    default {
      try {
        Get-ManualProcess -find $_
        exit
      } catch {
        Write-Error $_.Exception.Message
        Start-Sleep -Seconds 3
        Get-InitialInput
        exit
      }
    }
  }
}

Get-InitialInput