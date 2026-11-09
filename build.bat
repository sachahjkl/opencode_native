@echo off
:: Shortcut: build.bat [debug|release] [--force] is ocntools build (tools\ocntools; GT=<folder> another toolkit, OUT=<file>).
:: Every other step: odin run tools\ocntools -collection:gt=ext/gui_toolkit/src -out:build\ocntools.exe -- <command> (help lists them).
cd /D "%~dp0"
if not exist build mkdir build
odin run tools\ocntools -collection:gt=ext/gui_toolkit/src -out:build\ocntools.exe -keep-executable -- build %*
