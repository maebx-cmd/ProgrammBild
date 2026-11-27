"""Bereitet Apples MobileCLIP (S0) für die App vor – läuft im Build auf dem Mac-Runner.

1. Lädt mobileclip_s0_image + mobileclip_s0_text (Core ML) von Hugging Face (apple/coreml-mobileclip).
2. Berechnet mit dem Text-Encoder die Embeddings der Klassen (Frau / Mann / keine Person)
   aus mehreren Beschreibungen und mittelt sie.
3. Schreibt out/CLIPImage.mlpackage und out/CLIPClasses.json.

In der App läuft danach nur der Bild-Encoder – lokal, ohne Netz.
"""
import json
import os
import shutil
import sys

import coremltools as ct
import numpy as np
from huggingface_hub import snapshot_download
from transformers import CLIPTokenizer

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)

CLASSES = {
    "woman": ["a photo of a woman", "a photo of a girl", "a woman", "a photo of a young woman",
              "a selfie of a woman", "a photo of a female person"],
    "man": ["a photo of a man", "a photo of a guy", "a man", "a photo of a young man",
            "a selfie of a man", "a photo of a male person"],
    "none": ["a photo with no people", "a photo of an object", "a landscape photo",
             "a screenshot of text", "a photo of food", "a photo of an animal"],
}

path = snapshot_download("apple/coreml-mobileclip", allow_patterns=["mobileclip_s0_*"])
# Der HF-Cache besteht aus Symlinks – Core ML will echte, beschreibbare Dateien.
work = os.path.abspath("clip_work")
os.makedirs(work, exist_ok=True)
for n in ("mobileclip_s0_image.mlpackage", "mobileclip_s0_text.mlpackage"):
    shutil.copytree(os.path.join(path, n), os.path.join(work, n), symlinks=False, dirs_exist_ok=True)
img_pkg = os.path.join(work, "mobileclip_s0_image.mlpackage")
txt_pkg = os.path.join(work, "mobileclip_s0_text.mlpackage")

img = ct.models.MLModel(img_pkg, skip_model_load=True)
print("Bild-Encoder Eingänge:", img.get_spec().description.input)
print("Bild-Encoder Ausgänge:", [o.name for o in img.get_spec().description.output])
assert img.get_spec().description.input[0].type.WhichOneof("Type") == "imageType", "Bild-Encoder erwartet kein Bild"

txt = ct.models.MLModel(txt_pkg)
tin = txt.get_spec().description.input[0]
tout = txt.get_spec().description.output[0].name
print("Text-Encoder:", tin.name, tin.type, "->", tout)
shape = list(tin.type.multiArrayType.shape) or [1, 77]
ctx = int(shape[-1])
dtype = np.int32 if tin.type.multiArrayType.dataType == ct.proto.FeatureTypes_pb2.ArrayFeatureType.INT32 else np.float32

tok = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")

def embed(text: str) -> np.ndarray:
    ids = tok(text, padding="max_length", max_length=ctx, truncation=True)["input_ids"]
    arr = np.array(ids, dtype=dtype).reshape(shape)
    v = np.array(txt.predict({tin.name: arr})[tout], dtype=np.float32).reshape(-1)
    return v / np.linalg.norm(v)

result = {"logitScale": 100.0, "classes": []}
for name, prompts in CLASSES.items():
    m = np.mean([embed(p) for p in prompts], axis=0)
    m = m / np.linalg.norm(m)
    result["classes"].append({"name": name, "embedding": [round(float(x), 6) for x in m]})
    print(name, "dim", m.shape[0])

# Plausibilitätscheck: Frau/Mann-Prompts sollen sich unterscheiden
w, mn = (np.array(c["embedding"]) for c in result["classes"][:2])
print("Kosinus woman/man:", float(w @ mn))

with open(os.path.join(OUT, "CLIPClasses.json"), "w") as f:
    json.dump(result, f)
shutil.copytree(img_pkg, os.path.join(OUT, "CLIPImage.mlpackage"), dirs_exist_ok=True)
print("fertig:", os.listdir(OUT))
