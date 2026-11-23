"""Recreate the clean English audio replay with macOS say and Whisper Base."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from evaluate import HERE, SETS, read_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', choices=sorted(set(SETS.values())))
    parser.add_argument('model', type=Path, help='Local OpenAI Whisper Base multilingual .pt')
    parser.add_argument('output', type=Path, help='New JSONL for comparison')
    parser.add_argument('--voice', default='Samantha', help='Installed macOS English voice')
    args = parser.parse_args()

    import numpy as np
    import torch
    import whisper
    torch.set_num_threads(4)
    net = whisper.load_model(str(args.model.resolve(strict=True)), device='cpu')
    decode_options = whisper.DecodingOptions(language='en', fp16=False, without_timestamps=True)
    pages = read_json(HERE / (args.fixture + '.json'))
    with tempfile.TemporaryDirectory() as scratch, args.output.open('x', encoding='utf-8') as output:
        aiff = str(Path(scratch) / 'utterance.aiff')
        for i, page in enumerate(pages):
            for j, (speech, _) in enumerate(page['cases']):
                rate = 165 if j % 2 == 0 else 180
                subprocess.run(['say', '-v', args.voice, '-r', str(rate), '-o', aiff, speech], check=True)
                pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', aiff, '-f', 'f32le',
                                               '-ar', '16000', '-ac', '1', 'pipe:1'])
                waveform = np.frombuffer(pcm, dtype='float32').copy()
                mel = whisper.log_mel_spectrogram(whisper.pad_or_trim(waveform), n_mels=net.dims.n_mels)
                with torch.inference_mode():
                    text = net.decode(mel, decode_options).text.strip()
                print(json.dumps([i, j, text]), file=output, flush=True)


if __name__ == '__main__':
    main()
