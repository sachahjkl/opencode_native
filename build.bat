@echo off
:: Shortcut: build.bat [debug|release] [--force] is occtools build (tools\occtools; GT=<folder> another toolkit, OUT=<file>).
:: Every other step: odin run tools\occtools -collection:gt=ext/gui_toolkit/src -out:build\occtools.exe -- <command> (help lists them).
cd /D "%~dp0" && odin run tools\occtools -collection:gt=ext/gui_toolkit/src -out:build\occtools.exe -keep-executable -- build %*
