@echo off
rem RobBox CAD конструктор — запуск GUI (WPF требует STA)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0robbox_gui.ps1"
