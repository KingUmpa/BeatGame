@echo off
rem run.bat - Command Prompt wrapper around run.ps1. Same modes:
rem   run            the game  (run play --song=songs/x.json --from=2: one song, from its level 2)
rem   run juice      the juice editor
rem   run levels     the level editor
rem   run export     the song to exports\ (with and without backing)
rem   run test       unit tests
rem   run package -Version 0.1   Windows + Mac builds in dist\
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
