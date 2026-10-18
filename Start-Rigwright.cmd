@echo off
rem Rigwright launcher - Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC - MIT License
title Rigwright
rem Signed releases (SIGNED marker written at build time) run under RemoteSigned; dev builds need Bypass for this process only.
set "RW_EP=Bypass"
if exist "%~dp0SIGNED" set "RW_EP=RemoteSigned"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy %RW_EP% -File "%~dp0Rigwright.ps1" %*
