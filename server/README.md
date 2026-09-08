---
title: LipsLink API
emoji: 👄
colorFrom: blue
colorTo: purple
sdk: docker
app_port: 7860
pinned: false
---

# LipsLink API

FastAPI + PyTorch service that reads lip movements. The LipsLink Flutter app
sends a batch of cropped mouth images and gets back the recognised text.

## Endpoints

| Method | Path       | Purpose                                        |
| ------ | ---------- | ---------------------------------------------- |
| GET    | `/health`  | Liveness check plus which models are loaded     |
| GET    | `/models`  | Model list with their configs and vocab sizes   |
| POST   | `/predict` | Run a prediction over base64-encoded PNG frames |

`POST /predict` takes `frames` (a list of base64 PNG strings), an optional
`face_frames` list for the dual-stream model, and `model` (`model1` or
`model2`).

## Pointing the app at this Space

A Space is served at `https://<username>-<space-name>.hf.space`, so build the
Flutter app with that as the API base URL:

```
flutter build apk --dart-define=API_BASE_URL=https://<username>-<space-name>.hf.space
```

## Notes for deploying

The two checkpoints under `models/` are about 15MB each, which is over the
Hugging Face 10MB threshold, so they have to be tracked with Git LFS before
the first push:

```
git lfs install
git lfs track "*.pt"
git add .gitattributes
```

The container reads its port from `$PORT` and falls back to 7860, which is what
`app_port` above declares.
