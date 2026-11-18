// @ts-check
const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

/** @param {vscode.ExtensionContext} context */
function activate(context) {
  const appBundle = context.asAbsolutePath(path.join('bin', 'IPhoneCapture.app'));
  const helper = path.join(appBundle, 'Contents', 'MacOS', 'iphone-capture');
  try { fs.chmodSync(helper, 0o755); } catch { /* ignore */ }

  context.subscriptions.push(
    vscode.commands.registerCommand('instantNotes.takePhoto', (uri) => takePhoto(appBundle, 'continuity', uri)),
    vscode.commands.registerCommand('instantNotes.takePhotoInstant', (uri) => takePhoto(appBundle, 'webcam', uri)),
    vscode.commands.registerCommand('instantNotes.convertHeic', (uri, uris) => convertHeic(helper, uri, uris))
  );
}

/**
 * Folder to save into: explorer selection (folder or file's folder) → active editor's folder → workspace root.
 * @param {vscode.Uri | undefined} uri
 */
function resolveTargetFolder(uri) {
  if (uri && uri.scheme === 'file') {
    try {
      return fs.statSync(uri.fsPath).isDirectory() ? uri.fsPath : path.dirname(uri.fsPath);
    } catch { /* fall through */ }
  }
  const doc = vscode.window.activeTextEditor?.document;
  if (doc && doc.uri.scheme === 'file') return path.dirname(doc.uri.fsPath);

  // Non-text editors (e.g. image preview) still expose their uri via tabs.
  const tabInput = vscode.window.tabGroups.activeTabGroup.activeTab?.input;
  // @ts-ignore - most tab inputs have a `uri`
  const tabUri = tabInput && tabInput.uri;
  if (tabUri instanceof vscode.Uri && tabUri.scheme === 'file') return path.dirname(tabUri.fsPath);

  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
}

function buildBaseName(pattern) {
  const now = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const date = `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}`;
  const time = `${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
  const doc = vscode.window.activeTextEditor?.document;
  const fileBasename = doc ? path.parse(doc.fileName).name : 'photo';
  const name = pattern
    .replace(/\$\{date\}/g, date)
    .replace(/\$\{time\}/g, time)
    .replace(/\$\{fileBasename\}/g, fileBasename);
  return name.replace(/[\/\\:*?"<>|]/g, '_') || `IMG_${date}_${time}`;
}

/**
 * Runs the helper and resolves with its JSON result.
 * @param {string} helper @param {string[]} args @param {vscode.CancellationToken} [token]
 * @returns {Promise<any>}
 */
function runHelper(helper, args, token) {
  return new Promise((resolve, reject) => {
    const child = spawn(helper, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    token?.onCancellationRequested(() => child.kill('SIGTERM'));
    child.on('error', reject);
    child.on('close', (code) => {
      const line = out.trim().split('\n').filter(Boolean).pop();
      let result;
      try { result = line ? JSON.parse(line) : undefined; } catch { /* ignore */ }
      if (!result) {
        if (token?.isCancellationRequested || code === 2) return resolve({ ok: false, cancelled: true });
        return reject(new Error(err.trim() || `helper exited with code ${code}`));
      }
      resolve(result);
    });
  });
}

/**
 * Launches the helper app through LaunchServices (`open`) so macOS gives it foreground
 * focus — Continuity Camera only lists iPhones for the active app. The result comes back
 * through a temp file because `open` doesn't forward stdout.
 * @param {string} appBundle @param {string[]} args @param {vscode.CancellationToken} token
 * @returns {Promise<any>}
 */
function runHelperApp(appBundle, args, token) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'instant-notes-'));
  const resultFile = path.join(dir, 'result.json');
  const cleanup = () => fs.rmSync(dir, { recursive: true, force: true });
  return new Promise((resolve, reject) => {
    const child = spawn('open', ['-n', '-W', '-a', appBundle, '--args', ...args, '--result', resultFile], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let err = '';
    child.stderr.on('data', (d) => (err += d));
    // A helper launched from the editor can't bring itself forward on recent macOS, and
    // Continuity Camera only lists devices for the active app — so activate it for it.
    let tries = 0;
    const activate = setInterval(() => {
      if (fs.existsSync(resultFile + '.pid') || ++tries > 30) {
        clearInterval(activate);
        spawn('osascript', ['-e', 'tell application id "local.vscode.iphone-capture" to activate'], { stdio: 'ignore' });
      }
    }, 100);
    token.onCancellationRequested(() => {
      try { process.kill(Number(fs.readFileSync(resultFile + '.pid', 'utf8')), 'SIGTERM'); } catch { /* ignore */ }
    });
    child.on('error', (e) => { cleanup(); reject(e); });
    child.on('close', (code) => {
      clearInterval(activate);
      let result;
      try { result = JSON.parse(fs.readFileSync(resultFile, 'utf8')); } catch { /* ignore */ }
      cleanup();
      if (result) return resolve(result);
      if (token.isCancellationRequested) return resolve({ ok: false, cancelled: true });
      reject(new Error(err.trim() || `helper exited with code ${code}`));
    });
  });
}

/**
 * @param {string} appBundle @param {'continuity' | 'webcam'} mode @param {vscode.Uri} [uri]
 */
async function takePhoto(appBundle, mode, uri) {
  if (process.platform !== 'darwin') {
    vscode.window.showErrorMessage('Instant Notes 仅支持 macOS（需要连续互通相机）。');
    return;
  }
  const cfg = vscode.workspace.getConfiguration('instantNotes');
  let folder = resolveTargetFolder(uri);
  if (!folder) {
    vscode.window.showErrorMessage('请先打开一个文件或文件夹，以确定照片保存位置。');
    return;
  }
  const sub = String(cfg.get('subfolder') || '').trim();
  if (sub) {
    folder = path.join(folder, sub);
    fs.mkdirSync(folder, { recursive: true });
  }

  // Remember the editor now — focus moves to the helper window while shooting.
  const editor = vscode.window.activeTextEditor;

  const args = [
    '--mode', mode,
    '--out', folder,
    '--name', buildBaseName(String(cfg.get('fileNamePattern') || 'IMG_${date}_${time}')),
    '--quality', String(cfg.get('jpegQuality') ?? 0.92),
    '--timeout', String(cfg.get('timeoutSeconds') ?? 180),
  ];
  if (cfg.get('keepOriginalHeic')) args.push('--keep-original');
  const device = String(cfg.get('deviceName') || '').trim();
  if (device) args.push('--device', device);

  const title = mode === 'webcam' ? '正在用 iPhone 拍照…' : 'iPhone 相机已打开：按快门后点「使用照片」…';

  let result;
  try {
    result = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title, cancellable: true },
      (_p, token) => runHelperApp(appBundle, args, token)
    );
  } catch (e) {
    vscode.window.showErrorMessage(`iPhone 拍照失败：${e instanceof Error ? e.message : e}`);
    return;
  }

  if (!result.ok) {
    if (!result.cancelled) vscode.window.showErrorMessage(`iPhone 拍照失败：${result.error}`);
    else if (result.error && result.error !== '用户取消' && result.error !== '用户关闭窗口') {
      vscode.window.showWarningMessage(`iPhone 拍照已取消：${result.error}`);
    }
    return;
  }

  const saved = vscode.Uri.file(result.path);
  if (cfg.get('insertMarkdownLink') && editor && editor.document.languageId === 'markdown') {
    const rel = path.relative(path.dirname(editor.document.uri.fsPath), result.path).split(path.sep).join('/');
    const link = `![${path.parse(result.path).name}](${encodeURI(rel)})`;
    await editor.edit((b) => b.replace(editor.selection, link));
  }

  const note = result.converted ? `（${String(result.originalFormat).toUpperCase()} 已转为 JPEG）` : '';
  const choice = await vscode.window.showInformationMessage(
    `已保存 ${path.basename(result.path)}${note}`,
    '打开',
    '在资源管理器中显示'
  );
  if (choice === '打开') vscode.commands.executeCommand('vscode.open', saved);
  else if (choice === '在资源管理器中显示') vscode.commands.executeCommand('revealInExplorer', saved);
}

/**
 * Converts selected .heic/.heif files in the explorer to JPEG next to the original.
 * @param {string} helper @param {vscode.Uri} uri @param {vscode.Uri[]} [uris]
 */
async function convertHeic(helper, uri, uris) {
  const list = (uris && uris.length ? uris : [uri]).filter((u) => u && /\.(heic|heif)$/i.test(u.fsPath));
  if (!list.length) return;
  const quality = String(vscode.workspace.getConfiguration('instantNotes').get('jpegQuality') ?? 0.92);
  let ok = 0;
  for (const u of list) {
    try {
      const r = await runHelper(helper, ['--convert', u.fsPath, '--quality', quality]);
      if (r.ok) ok++;
      else vscode.window.showErrorMessage(`${path.basename(u.fsPath)} 转换失败：${r.error}`);
    } catch (e) {
      vscode.window.showErrorMessage(`${path.basename(u.fsPath)} 转换失败：${e instanceof Error ? e.message : e}`);
    }
  }
  if (ok) vscode.window.showInformationMessage(`已将 ${ok} 个文件转换为 JPEG。`);
}

function deactivate() {}

module.exports = { activate, deactivate };
