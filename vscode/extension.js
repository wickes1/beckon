// beckon's VS Code side. The beckon app can bring VS Code forward by itself, but only an extension can tell
// which window owns a given terminal and switch to it. Each window's extension host runs one copy of this,
// listening on its own Unix socket and announcing it in a registry file the app reads:
//   ~/Library/Application Support/beckon/vscode/<extension-host pid>.json  →  { pid, socket }
// The app sends one JSON line { cmd, pids } — pids being the Claude Code hook's parent chain — and the window
// that owns the session answers with `match`:
//   "terminal"  one of this window's integrated terminals has its shell in that chain
//   "host"      the chain runs through this extension host: the session is in the Claude Code side panel
const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');

const dir = path.join(os.homedir(), 'Library', 'Application Support', 'beckon', 'vscode');
const registry = path.join(dir, `${process.pid}.json`);
const socketPath = path.join(dir, `${process.pid}.sock`);
let server;

async function terminalFor(pids) {
  for (const terminal of vscode.window.terminals) {
    const pid = await terminal.processId;
    if (pid && pids.includes(pid)) return terminal;
  }
  return undefined;
}

// What `open -b <VS Code> <path>` needs to raise this window: the workspace file, else the first folder.
// Empty for remote and untitled workspaces — the app then just brings VS Code forward.
function workspacePath() {
  const file = vscode.workspace.workspaceFile;
  if (file && file.scheme === 'file') return file.fsPath;
  const folder = (vscode.workspace.workspaceFolders || [])[0];
  return folder && folder.uri.scheme === 'file' ? folder.uri.fsPath : '';
}

async function handle(message) {
  const pids = Array.isArray(message.pids) ? message.pids : [];
  const terminal = await terminalFor(pids);
  const match = terminal ? 'terminal' : pids.includes(process.pid) ? 'host' : null;
  if (!match) return { match };
  if (message.cmd === 'state') {
    return { match, focused: vscode.window.state.focused, activeTerminal: !!terminal && vscode.window.activeTerminal === terminal };
  }
  if (message.cmd === 'focus') {
    if (terminal) terminal.show(false);
    // Side-panel session: the Claude Code extension's own command puts the cursor in its input.
    else await vscode.commands.executeCommand('claude-vscode.focus').then(undefined, () => {});
    return { match, workspace: workspacePath() };
  }
  return { match };
}

function removeFiles() {
  for (const file of [registry, socketPath]) {
    try { fs.unlinkSync(file); } catch { /* already gone */ }
  }
}

function activate(context) {
  if (process.platform !== 'darwin') return;
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  removeFiles();
  server = net.createServer((connection) => {
    let buffer = '';
    connection.setEncoding('utf8');
    connection.on('error', () => {});
    connection.on('data', (chunk) => {
      buffer += chunk;
      const end = buffer.indexOf('\n');
      if (end < 0) return;
      let message;
      try { message = JSON.parse(buffer.slice(0, end)); } catch { connection.destroy(); return; }
      handle(message).then(
        (reply) => connection.end(JSON.stringify(reply) + '\n'),
        () => connection.end(JSON.stringify({ match: null }) + '\n'),
      );
    });
  });
  server.on('error', (error) => console.error('beckon: socket error', error));
  server.listen(socketPath, () => {
    fs.chmodSync(socketPath, 0o600);
    fs.writeFileSync(registry, JSON.stringify({ pid: process.pid, socket: socketPath }), { mode: 0o600 });
  });
  context.subscriptions.push({ dispose: deactivate });
}

function deactivate() {
  if (server) { server.close(); server = undefined; }
  removeFiles();
}

module.exports = { activate, deactivate };
