#!/usr/bin/env python3
"""Reference embedding server for Linux/macOS evaluation of PersonalAICore (NOT shipped in the app).

Runs all-MiniLM-L6-v2 (Apache-2.0, 384-d, 22M params) through ONNX Runtime and speaks line-delimited JSON on stdio:
  request : {"texts": ["...", ...]}   response: {"dim": 384, "vectors": [[...], ...]}
The on-device app uses an MLX / Core ML embedder instead; this exists so retrieval *quality* can be measured on Linux with a
genuine neural embedder. Model files: model.onnx + tokenizer.json in $PAI_MINILM_DIR (see docs/EVAL.md for the download).
"""
import json, os, sys
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

d = os.environ.get("PAI_MINILM_DIR", "/tmp/claude-0/minilm")
tok = Tokenizer.from_file(os.path.join(d, "tokenizer.json"))
tok.enable_truncation(max_length=256)
tok.enable_padding(pad_id=0, pad_token="[PAD]")
so = ort.SessionOptions(); so.intra_op_num_threads = int(os.environ.get("PAI_THREADS", "4"))
sess = ort.InferenceSession(os.path.join(d, "model.onnx"), so, providers=["CPUExecutionProvider"])
names = {i.name for i in sess.get_inputs()}

def embed(texts):
    out = []
    order = sorted(range(len(texts)), key=lambda i: len(texts[i]))          # length-bucket to limit padding
    res = [None] * len(texts)
    for s in range(0, len(order), 32):
        idx = order[s:s + 32]
        enc = tok.encode_batch([texts[i] for i in idx])
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in names: feed["token_type_ids"] = np.zeros_like(ids)
        h = sess.run(None, feed)[0]
        m = mask[..., None].astype(np.float32)
        v = (h * m).sum(1) / np.maximum(m.sum(1), 1e-9)
        v /= np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-9)
        for j, i in enumerate(idx): res[i] = v[j]
    return res

for line in sys.stdin:
    req = json.loads(line)
    vs = embed(req["texts"]) if req["texts"] else []
    sys.stdout.write(json.dumps({"dim": 384, "vectors": [[round(float(x), 6) for x in v] for v in vs]}) + "\n")
    sys.stdout.flush()
