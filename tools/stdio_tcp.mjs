#!/usr/bin/env node
// A TCP connection on stdin and stdout: lets a program in WSL reach a port of Windows's own 127.0.0.1 (tools/wsl_client.sh).
//   node tools/stdio_tcp.mjs <host> <port>
import { connect } from 'node:net'

const [host, port] = process.argv.slice(2)
const socket = connect(Number(port), host)
process.stdin.pipe(socket)
socket.pipe(process.stdout)
socket.on('error', () => process.exit(1))
socket.on('close', () => process.exit(0))
