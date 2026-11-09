"""Install the read-only process viewer into Katachi Loop Studio's web UI.

The viewer (katachi_web/process.*) is display-only: it reads finished runs through Katachi's
existing GET endpoints and never changes runs, projects or Katachi's Python code.
Installing copies three new files into Katachi's web folder and adds two links to the
studio page (index.html / app.js). Uninstalling reverses exactly those edits.
"""
from __future__ import annotations
import hashlib
import shutil
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / 'katachi_web'
FILES = ('process.html', 'process.js', 'process.css')
BACKUP = '.backup_web_original'

# (original text, patched text). Anchors match Katachi Loop Studio 0.5.0.
PATCHES = {
    'index.html': [
        ('<a id="download-kit" class="secondary" hidden>Run bundle</a>',
         '<a id="download-kit" class="secondary" hidden>Run bundle</a><a id="process-link" class="secondary" hidden>工程を見る</a>'),
        ('<button id="help" class="quiet">Guide</button></div></header>',
         '<a class="quiet" href="/process.html">工程ビューア</a><button id="help" class="quiet">Guide</button></div></header>'),
    ],
    'app.js': [
        ("$('download-kit').hidden=!job.result;$('download-kit').href='/api/jobs/'+id+'/download';",
         "$('download-kit').hidden=!job.result;$('download-kit').href='/api/jobs/'+id+'/download';"
         "$('process-link').hidden=!job.result;$('process-link').href='/process.html?job='+id;"),
        ("$('download-kit').hidden=true;$('accept').hidden=true;",
         "$('download-kit').hidden=true;$('process-link').hidden=true;$('accept').hidden=true;"),
    ],
}


class ViewerError(RuntimeError):
    pass


def katachi_web(katachi: str | Path | None = None) -> Path:
    """Katachi's web folder: from --katachi, else from the installed katachi package."""
    if katachi:
        root = Path(katachi)
        web = root if (root / 'viewer.js').exists() else root / 'web'
    else:
        try:
            from katachi.resources import resource_root
            web = Path(resource_root()) / 'web'
        except Exception as exc:  # pragma: no cover - depends on the local install
            raise ViewerError(f'Katachi is not importable ({exc}); pass --katachi <folder>') from exc
    for name in ('viewer.js', 'index.html', 'app.js'):
        if not (web / name).is_file():
            raise ViewerError(f'{web} does not look like Katachi\'s web folder ({name} missing)')
    return web


def _read(path: Path) -> str:
    return path.read_bytes().decode('utf-8')


def _write(path: Path, text: str):
    path.write_bytes(text.encode('utf-8'))


def _patch_state(text: str, patches) -> str:
    if all(new in text for _, new in patches):
        return 'patched'
    if all(text.count(old) == 1 and new not in text for old, new in patches):
        return 'original'
    return 'unknown'


def _digest(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def status(katachi=None) -> dict:
    web = katachi_web(katachi)
    files = {}
    for name in FILES:
        target = web / name
        files[name] = ('missing' if not target.exists()
                       else 'current' if _digest(target) == _digest(ASSETS / name) else 'different')
    patches = {name: _patch_state(_read(web / name), p) for name, p in PATCHES.items()}
    installed = all(v == 'current' for v in files.values()) and all(v == 'patched' for v in patches.values())
    return {'web': str(web), 'installed': installed, 'files': files, 'patches': patches}


def install(katachi=None) -> dict:
    web = katachi_web(katachi)
    texts = {name: _read(web / name) for name in PATCHES}
    states = {name: _patch_state(texts[name], p) for name, p in PATCHES.items()}
    bad = [n for n, s in states.items() if s == 'unknown']
    if bad:  # validate everything before writing anything
        raise ViewerError(f'unexpected contents in {", ".join(bad)} (not Katachi 0.5.0?); nothing was changed')
    backup = web.parent / BACKUP
    for name, state in states.items():
        if state == 'original':
            backup.mkdir(exist_ok=True)
            if not (backup / name).exists():
                shutil.copy2(web / name, backup / name)
            text = texts[name]
            for old, new in PATCHES[name]:
                text = text.replace(old, new)
            _write(web / name, text)
    for name in FILES:
        shutil.copyfile(ASSETS / name, web / name)
    return status(web)


def uninstall(katachi=None) -> dict:
    web = katachi_web(katachi)
    for name, patches in PATCHES.items():
        text = _read(web / name)
        if _patch_state(text, patches) == 'patched':
            for old, new in patches:
                text = text.replace(new, old)
            _write(web / name, text)
    for name in FILES:
        (web / name).unlink(missing_ok=True)
    return status(web)


def main(args) -> int:
    action = {'install': install, 'uninstall': uninstall, 'status': status}[args.action]
    try:
        info = action(args.katachi)
    except ViewerError as exc:
        print(f'error: {exc}')
        return 1
    print(f"Katachi web: {info['web']}")
    for name, state in {**info['files'], **info['patches']}.items():
        print(f'  {name:<12} {state}')
    print('installed' if info['installed'] else 'not installed')
    if args.action == 'install':
        print('open http://127.0.0.1:8765/process.html (no server restart needed)')
    return 0
