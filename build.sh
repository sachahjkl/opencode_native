#!/usr/bin/env bash
# Shortcut: ./build.sh [debug|release] [--force] is ocntools build (tools/ocntools; GT=<folder> another toolkit, OUT=<file>).
# Every other step: odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- <command> (help lists them).
cd "$(dirname "$0")" && mkdir -p build && exec odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -keep-executable -- build "$@"
