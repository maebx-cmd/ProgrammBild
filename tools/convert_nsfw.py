"""Wandelt GantMans offenes NSFW-Modell (MobileNet v2, 224x224) in Core ML um.
Läuft im GitHub-Actions-Build, nicht am iPhone. Ergebnis: NSFW.mlpackage

Aufruf: convert_nsfw.py <saved_model-Verzeichnis> <out.mlpackage> [class_labels.txt]"""
import sys
import coremltools as ct
import tensorflow as tf

src, out = sys.argv[1], sys.argv[2]
labels = ["drawings", "hentai", "neutral", "porn", "sexy"]  # Reihenfolge laut Modell-README
if len(sys.argv) > 3:
    labels = [l.strip() for l in open(sys.argv[3]) if l.strip()] or labels
print("Klassen:", labels)

# SavedModel laden (enthält die TF-Hub-Schicht bereits) und als feste Funktion exportieren
loaded = tf.saved_model.load(src)
sig = loaded.signatures["serving_default"]
print("Signatur-Eingänge:", sig.structured_input_signature)
print("Signatur-Ausgänge:", sig.structured_outputs)

@tf.function(input_signature=[tf.TensorSpec([1, 224, 224, 3], tf.float32, name="image")])
def infer(x):
    res = sig(x) if not isinstance(sig.structured_input_signature[1], dict) or len(sig.structured_input_signature[1]) != 1 \
        else sig(**{list(sig.structured_input_signature[1].keys())[0]: x})
    return list(res.values())[0]

ml = ct.convert(
    [infer.get_concrete_function()],
    source="tensorflow",
    inputs=[ct.ImageType(name="image", shape=(1, 224, 224, 3), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    classifier_config=ct.ClassifierConfig(labels),
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS16,
)
ml.short_description = "NSFW-Klassifizierer (GantMan nsfw_model, MobileNet v2)"
ml.save(out)
print("gespeichert:", out)
