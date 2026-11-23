"""FineCat Ultra L inference for short English speech/claim pairs on Mac CPU."""
import json
import struct
from pathlib import Path

import numpy as np
from tokenizers import Tokenizer


def load_weights(path):
    """Map the verified FP32 safetensors file without copying its 1.51 GB payload."""
    with path.open('rb') as f:
        size = struct.unpack('<Q', f.read(8))[0]
        if size > 8_000_000:
            raise ValueError('Invalid tensor header')
        tensors = json.loads(f.read(size))
    data = np.memmap(path, mode='r', dtype='uint8', offset=8 + size)
    result = {}
    for name, entry in tensors.items():
        if name == '__metadata__':
            continue
        if entry['dtype'] != 'F32':
            raise ValueError('Unexpected FineCat weight type')
        start, end = entry['data_offsets']
        result[name] = data[start:end].view('<f4').reshape(entry['shape'])
    return result


def softmax(x):
    exp = np.exp(x - x.max(axis=-1, keepdims=True))
    return exp / exp.sum(axis=-1, keepdims=True)


class FineCat:
    def __init__(self, directory):
        directory = Path(directory)
        self.config = json.loads((directory / 'config.json').read_text())
        if self.config['architectures'] != ['UltrabertForSequenceClassification'] or self.config['id2label']['0'] != 'entailment':
            raise ValueError('Expected the English FineCat Ultra L classifier')
        self.w = load_weights(directory / 'model.safetensors')
        self.tokenizer = Tokenizer.from_file(str(directory / 'tokenizer.json'))
        self.tokenizer.no_padding()
        self.tokenizer.no_truncation()

    def logits(self, ids, valid):
        cfg, w = self.config, self.w
        head_dim, heads = cfg['head_dim'], cfg['num_attention_heads']
        length = ids.shape[1]
        positions = np.arange(length, dtype=np.float32)
        delta = np.abs(positions[:, None] - positions)
        rotation = {}
        for base in set(cfg['rope_theta']):
            angle = positions[:, None] * np.float32(base) ** (-np.arange(0, head_dim, 2, dtype=np.float32) / head_dim)
            angle = np.concatenate((angle, angle), axis=-1)
            rotation[base] = (np.cos(angle), np.sin(angle))

        def norm(x, key):
            return x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + cfg['rms_norm_eps']) * w[key]

        hidden = w['ultrabert.embed_tokens.weight'][ids]
        for layer in range(cfg['num_hidden_layers']):
            prefix = f'ultrabert.layers.{layer}.'
            x = norm(hidden, prefix + 'input_layernorm.weight')
            def project(part):
                return (x @ w[prefix + 'self_attn.' + part + '_proj.weight'].T).reshape(
                    len(ids), length, heads, head_dim).transpose(0, 2, 1, 3)

            cos, sin = rotation[cfg['rope_theta'][layer]]
            def rotate(tensor):
                first, second = np.split(tensor, 2, axis=-1)
                return tensor * cos + np.concatenate((-second, first), axis=-1) * sin

            q, k, v = rotate(project('q')), rotate(project('k')), project('v')
            scores = (q @ k.swapaxes(-1, -2)) * np.float32(head_dim ** -0.5)
            mask = valid[:, None, None, :]
            window = cfg['attention_windows'][layer]
            if window:
                mask = mask & (delta <= window)
            attn = (softmax(np.where(mask, scores, np.float32(-1e30))) @ v).transpose(0, 2, 1, 3)
            hidden = hidden + attn.reshape(hidden.shape) @ w[prefix + 'self_attn.o_proj.weight'].T
            x = norm(hidden, prefix + 'post_attention_layernorm.weight')
            gate = x @ w[prefix + 'mlp.gate_proj.weight'].T
            gate = gate / (1 + np.exp(-np.clip(gate, -80, 80)))
            hidden = hidden + (gate * (x @ w[prefix + 'mlp.up_proj.weight'].T)) @ w[prefix + 'mlp.down_proj.weight'].T
        first = norm(hidden[:, 0], 'ultrabert.norm.weight')
        return first @ w['classifier.weight'].T + w['classifier.bias']

    def score(self, context, points):
        values = [0.] * len(points)
        for start in range(0, len(points), 8):
            batch = self.tokenizer.encode_batch([(context, p) for p in points[start:start + 8]])
            # Abstain on excessively long individual pairs instead of truncating a negation.
            rows = [(start+j, item.ids) for j, item in enumerate(batch) if 0 < len(item.ids) <= 512]
            if not rows:
                continue
            size = max(len(tokens) for _, tokens in rows)
            ids = np.zeros((len(rows), size), dtype=np.int32)
            valid = np.zeros(ids.shape, dtype=bool)
            for j, (_, tokens) in enumerate(rows):
                ids[j, :len(tokens)] = tokens
                valid[j, :len(tokens)] = True
            for (index, _), prob in zip(rows, softmax(self.logits(ids, valid))[:, 0]):
                values[index] = float(prob)
        return values
