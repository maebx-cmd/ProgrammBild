"""Wandelt GantMans offenes NSFW-Modell (MobileNet v2, 224x224) in Core ML um.
Läuft im GitHub-Actions-Build, nicht am iPhone. Ergebnis: NSFW.mlpackage"""
import sys
import coremltools as ct
import tensorflow as tf

h5 = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else "NSFW.mlpackage"

model = tf.keras.models.load_model(h5, compile=False)
print("Eingang:", model.input_shape, "Ausgang:", model.output_shape)

labels = ["drawings", "hentai", "neutral", "porn", "sexy"]  # Reihenfolge laut Modell-README
assert model.output_shape[-1] == len(labels)

ml = ct.convert(
    model,
    inputs=[ct.ImageType(name="image", shape=(1, 224, 224, 3), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    classifier_config=ct.ClassifierConfig(labels),
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS16,
)
ml.short_description = "NSFW-Klassifizierer (GantMan nsfw_model, MobileNet v2)"
ml.save(out)
print("gespeichert:", out)
