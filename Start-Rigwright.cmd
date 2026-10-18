@echo off
rem Rigwright launcher - Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC - MIT License
title Rigwright
rem -ExecutionPolicy Bypass applies to this one process only. It also lets Rigwright start from a network share
rem or a mapped drive, where RemoteSigned would refuse the scripts.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rigwright.ps1" %*
