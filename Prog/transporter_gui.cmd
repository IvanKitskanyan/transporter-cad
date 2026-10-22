@echo off
rem Transporter CAD конструктор — запуск GUI (WPF требует STA)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0transporter_gui.ps1"
