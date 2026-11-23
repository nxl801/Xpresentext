"""Persistent local process. Only explicit preparation can access the model repository."""
import hashlib
import json
from pathlib import Path
import sys

from .decision import check_coverage
from .model import FineCat

REPO = 'dleemiller/finecat-nli-ultra-l'
REVISION = '5fe8dd8e605643793a091de2da0057697a558c9a'
DIGEST = '92b459f6c659719bd3a7f8915d975283a197889ec97b0f26cdc55daa5a3d14e8'
CHECKSUMS = {
    'config.json': '85bfd05c47462dab3d0ee7c27003866609bb0d048562997399d2cd87cbf3d8ec',
    'tokenizer.json': 'c6f4f1115422c511873bada36a1faa66fd859d81346401b410046297fa134223',
    'model.safetensors': DIGEST,
}
FILES = tuple(CHECKSUMS)


def event(kind, **fields):
    print(json.dumps(dict(type=kind, **fields)), flush=True)


def verified(path):
    with path.open('rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    if digest != CHECKSUMS[path.name]:
        raise ValueError('权重校验失败，请重新准备官方 FineCat Ultra L 文件。')


def load(mode, imported=None):
    store = Path.home() / 'Library/Application Support/TextreamStudio/FineCat' / REVISION
    directory = Path(imported) if imported else store
    if not all((directory / file).is_file() for file in FILES):
        if imported:
            raise ValueError('目录需要包含 config.json、tokenizer.json 和 model.safetensors。')
        from huggingface_hub import snapshot_download
        try:
            cached = Path(snapshot_download(REPO, revision=REVISION, local_files_only=True, token=False))
            if all((cached / file).is_file() for file in FILES):
                directory = cached
        except OSError:
            pass
    if not all((directory / file).is_file() for file in FILES):
        if mode != 'prepare':
            event('missing')
            return None
        event('status', message='正在下载 FineCat（约 1.5 GB）…')
        snapshot_download(REPO, revision=REVISION, allow_patterns=list(FILES), local_dir=directory, token=False)
    event('status', message='正在校验本机权重并试算…')
    try:
        for file in FILES:
            verified(directory / file)
    except ValueError:
        if mode != 'prepare' or imported:
            raise
        # Replace only this app's pinned checkpoint when the user requests repair.
        from huggingface_hub import snapshot_download
        event('status', message='正在重新下载并校验模型文件…')
        directory = store
        snapshot_download(REPO, revision=REVISION, allow_patterns=list(FILES), local_dir=store,
                          force_download=True, token=False)
        for file in FILES:
            verified(store / file)
    model = FineCat(directory)
    # The packaged engine must reproduce a positive and a neutral pair measured
    # on the reference implementation before it is allowed to color user text.
    probs = model.score('Kids pay nothing to borrow a book from us.',
                        ['Children borrow books free of charge.', 'Members can renew loans online.'])
    if abs(probs[0] - .980) > .06 or probs[1] > .10:
        raise ValueError('本地模型试算与参考结果不符，请核对分词器和权重版本。')
    return model


def main():
    try:
        model = load(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
        if model is None:
            return 0
        event('ready')
        for line in sys.stdin:
            request = json.loads(line)
            pages = []
            for index, page in enumerate(request['pages']):
                if index and request.get('preferCurrent') and any(p >= .50 for p in pages[0]):
                    # The presenter always prefers a current-slide match.
                    values = [0.] * len(page['points'])
                else:
                    values = check_coverage(request['text'], page['points'], model.score, page['title'])
                pages.append(values)
            event('result', id=request['id'], scores=pages)
    except Exception as error:
        event('error', message=str(error)[:220] if isinstance(error, ValueError)
              else '模型未能准备或运行。可重试下载，或选择本机 FineCat 模型目录。')
        return 1
    return 0
