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
    Write-Host "Type in the low-end int value of the CPU affinity range you would like to set:" -ForegroundColor DarkGreen -BackgroundColor Black
    [int] $lowValue = Get-UserInput
    Write-Host " "
    Write-Host "Type in the high-end int value of the CPU affinity range you would like to set:" -ForegroundColor DarkGreen -BackgroundColor Black
    [int] $highValue = Get-UserInput
    Set-ProcessAffinity -lowUserCore $lowValue -highUserCore $highValue -process $findings
  } catch {
    Write-Warning "Cannot find specified process/error occurred"
    Write-Error $_.Exception.Message
    Get-InitialInput
  }
}

function Set-ProcessAffinity {
  param(
    [Parameter(Mandatory)]
    [ValidateScript(
      {($_ -match '^[0-9]+$') -and ($_ -lt $script:totalCores) -and ($_ -ge 0)}
    )]
    [int] $lowUserCore,
    [Parameter(Mandatory)]
    [ValidateScript(
      {($_ -match '^[0-9]+$') -and ($_ -lt $script:totalCores) -and ($_ -ge 0)}
    )]
    [int] $highUserCore,
    [Parameter(Mandatory)]
    $process
  )

  $affinityNumber = '0' * $lowUserCore
  [string] $affinityNumber = ('1' + ('1' * ($highUserCore - $lowUserCore)) + $affinityNumber)
  $affinityNumber = '0b' + ($affinityNumber | Out-String).PadLeft(64, '0')
  
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
      [long]$item.ProcessorAffinity = [long]$affinityNumber
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
  Write-Host "To change affinity, type the low-end CPU number of the affinity range you would like to set (hint, they start at 0)" -ForegroundColor DarkGreen -BackgroundColor Black
  Write-Host "To manually specify a process to match by name, type 'manual'" -ForegroundColor DarkGreen -BackgroundColor Black
  Write-Host "To cancel, type exit" -ForegroundColor DarkGreen -BackgroundColor Black
  $initialInput = Get-UserInput
  switch ($true) {
    ($initialInput -eq 'exit') {
      Write-Output "User requested exit, exitting"
      exit
    }
    ($initialInput -eq 'manual') {
      Get-ManualProcess
      exit
    }
    (($initialInput -match '^[0-9]+$') -and ([int]$initialInput -lt $script:totalCores) -and ([int]$initialInput -ge 0) -and ($defaultDet)) {
      try {
        [int] $lowValue = $initialInput
        Write-Host " "
        Write-Host "Type in the high-end int value of the CPU affinity range you would like to set:" -ForegroundColor DarkGreen -BackgroundColor Black
        [int] $highValue = Get-UserInput
        Set-ProcessAffinity -lowUserCore $lowValue -highUserCore $highValue -process $defaultDet
        exit
      } catch {
        Write-Warning "An error occurred"
        Write-Error $_.Exception.Message
        Start-Sleep -Seconds 3
        Get-InitialInput
        exit
      }
    }
    ($true) {
      if (!($initialInput -match '^[0-9]+$')) {
        try {
          Get-ManualProcess -find $initialInput
          exit
        } catch {
          Write-Warning "An error occurred"
          Write-Error $_.Exception.Message
          Get-InitialInput
          exit
        }
      }
      if (!$defaultDet) {
        Get-ManualProcess
        exit
      }
      try {
        [int] $lowValue = $initialInput
        Write-Host " "
        Write-Host "Type in the high-end int value of the CPU affinity range you would like to set:" -ForegroundColor DarkGreen -BackgroundColor Black
        [int] $highValue = Get-UserInput
        Set-ProcessAffinity -lowUserCore $lowValue -highUserCore $highValue -process $defaultDet
        exit
      } catch {
        Write-Warning "An error occurred"
        Write-Error $_.Exception.Message
        Start-Sleep -Seconds 3
        Get-InitialInput
        exit
      }
      exit
    }
  }
}

Get-InitialInput