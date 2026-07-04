# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a self-contained, single-file pype.exe and drops it into installer/
    so Install-Pype.ps1 / install.cmd can find it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$csproj     = Join-Path $repoRoot 'src\Pype.csproj'
$publishDir = Join-Path $repoRoot 'publish'
$installer  = Join-Path $repoRoot 'installer'

dotnet publish $csproj -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

Copy-Item -Path (Join-Path $publishDir 'pype.exe') -Destination $installer -Force
Write-Host "pype.exe published and copied to $installer" -ForegroundColor Green
