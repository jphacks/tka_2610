"""Tests for `kt viewer`: install / uninstall of the process viewer into a Katachi web folder.

Uses a fake web folder that carries the same anchor strings as Katachi Loop Studio 0.5.0,
so the tests never touch the real Katachi install.
"""
from __future__ import annotations
import shutil
import subprocess
from pathlib import Path

import pytest

from kt import viewer
from kt.cli import main

INDEX = ('<html><header class="top"><div class="top-right"><button id="help" class="quiet">Guide</button></div></header>\r\n'
         '<div class="actions"><a id="download-glb" class="primary" download>Download GLB</a>'
         '<a id="download-kit" class="secondary" hidden>Run bundle</a></div></html>\r\n')
APP = ("function chooseExample(){$('download-kit').hidden=true;$('accept').hidden=true;}\n"
       "function watchJob(id,job){$('download-kit').hidden=!job.result;$('download-kit').href='/api/jobs/'+id+'/download';}\n")


@pytest.fixture
def katachi(tmp_path):
    web = tmp_path / 'KatachiLoopStudio' / 'web'
    web.mkdir(parents=True)
    (web / 'index.html').write_bytes(INDEX.encode('utf-8'))
    (web / 'app.js').write_bytes(APP.encode('utf-8'))
    (web / 'viewer.js').write_text('export class Viewer{}', encoding='utf-8')
    return web.parent


def test_install_patches_once_and_copies_files(katachi):
    info = viewer.install(katachi)
    web = katachi / 'web'
    assert info['installed']
    for name in viewer.FILES:
        assert (web / name).read_bytes() == (viewer.ASSETS / name).read_bytes()
    index, app = (web / 'index.html').read_text(encoding='utf-8'), (web / 'app.js').read_text(encoding='utf-8')
    assert index.count('id="process-link"') == 1 and index.count('href="/process.html"') == 1
    assert app.count("$('process-link').hidden=!job.result") == 1 and app.count("$('process-link').hidden=true") == 1
    assert (web / 'index.html').read_bytes().count(b'\r\n') == 2  # CRLF line endings are preserved
    # originals are kept next to the web folder
    assert (katachi / viewer.BACKUP / 'index.html').read_bytes() == INDEX.encode('utf-8')
    assert (katachi / viewer.BACKUP / 'app.js').read_bytes() == APP.encode('utf-8')


def test_install_is_idempotent_and_uninstall_restores(katachi):
    viewer.install(katachi)
    viewer.install(katachi)
    web = katachi / 'web'
    assert (web / 'index.html').read_text(encoding='utf-8').count('id="process-link"') == 1
    info = viewer.uninstall(katachi)
    assert not info['installed']
    assert (web / 'index.html').read_bytes() == INDEX.encode('utf-8')
    assert (web / 'app.js').read_bytes() == APP.encode('utf-8')
    assert not any((web / name).exists() for name in viewer.FILES)


def test_unknown_katachi_version_changes_nothing(katachi):
    web = katachi / 'web'
    (web / 'app.js').write_text('// a different Katachi version\n', encoding='utf-8')
    with pytest.raises(viewer.ViewerError):
        viewer.install(katachi)
    assert (web / 'index.html').read_bytes() == INDEX.encode('utf-8')
    assert not any((web / name).exists() for name in viewer.FILES)
    assert not (katachi / viewer.BACKUP).exists()


def test_not_a_katachi_folder(tmp_path):
    with pytest.raises(viewer.ViewerError):
        viewer.katachi_web(tmp_path)


def test_cli_status_and_install(katachi, capsys):
    assert main(['viewer', 'status', '--katachi', str(katachi)]) == 0
    assert 'not installed' in capsys.readouterr().out
    assert main(['viewer', 'install', '--katachi', str(katachi / 'web')]) == 0
    assert capsys.readouterr().out.rstrip().splitlines()[-2] == 'installed'


@pytest.mark.skipif(shutil.which('node') is None, reason='node not installed')
def test_viewer_script_parses():
    js = viewer.ASSETS / 'process.js'
    result = subprocess.run(['node', '--check', str(js)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
