#!/usr/bin/env bash
# Shortcut: ./build.sh [debug|release] [--force] is occtools build (tools/occtools; GT=<folder> another toolkit, OUT=<file>).
# Every other step: odin run tools/occtools -collection:gt=ext/gui_toolkit/src -out:build/occtools -- <command> (help lists them).
cd "$(dirname "$0")" && exec odin run tools/occtools -collection:gt=ext/gui_toolkit/src -out:build/occtools -keep-executable -- build "$@"
