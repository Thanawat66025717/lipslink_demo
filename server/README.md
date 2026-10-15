# LipsLink API

FastAPI + PyTorch service that reads lip movements. The LipsLink Flutter app
sends a batch of cropped mouth images and gets back the recognised text.

## Endpoints

| Method | Path               | Purpose                                              |
| ------ | ------------------ | ---------------------------------------------------- |
| GET    | `/health`          | Liveness check plus which models are loaded          |
| GET    | `/models`          | Model list with their configs and vocab sizes        |
| GET    | `/word_model_info` | Preprocessing the word model expects (frames, ROI)   |
| POST   | `/predict_word`    | One of 44 Thai words, with top-3 and confidence      |
| POST   | `/predict_sentence`| Free Thai text via character CTC (experimental)      |
| GET    | `/v4/model_info`   | v4 word list (200), fps, clip length, crop settings  |
| POST   | `/v4/calibrate`    | Per-user stats from ~20 s of face frames              |
| POST   | `/v4/predict_word` | One of 200 words from full-face JPEG frames          |

The `/v4` endpoints live in `vocalip_v4.py` and load from `models/vocalip_v4/`.
They take full-face crops (not mouth crops) plus `timestamps_ms`, run MediaPipe on
the server, and never write images to disk. `test_v4_api.py` drives them from a
video file. See `คู่มือติดตั้งโมเดล_v4.md` from the model team for details.

Both predict endpoints take `frames` as base64 raw RGB mouth crops
(`frame_format: "rgb"`, plus `roi`) and `capture_ms`. The word model loads from
`models/*_deployment.pt`; the sentence model from `models/vocalip_th_ctc/`.

## Deploying to Google Cloud Run

Cloud Run injects `$PORT`, which the Dockerfile already reads, so the image
needs no changes. Everything below runs in Cloud Shell from the browser, so
there is nothing to install locally.

1. Create a project at <https://console.cloud.google.com> and enable billing on
   it. Billing has to be on even to use the free monthly allowance.
2. Open Cloud Shell with the terminal icon at the top right of the console.
3. Clone this repository and enter the server directory:

   ```
   git clone https://github.com/Thanawat66025717/lipslink_demo.git
   cd lipslink_demo/server
   ```

4. Deploy. Answer yes when it offers to enable the Cloud Run, Cloud Build and
   Artifact Registry APIs:

   ```
   gcloud run deploy lipslink-api \
     --source . \
     --region asia-southeast1 \
     --allow-unauthenticated \
     --memory 2Gi \
     --cpu 2 \
     --timeout 300
   ```

5. The command prints a service URL. Check it with `<url>/health`, then build
   the app against it:

   ```
   flutter build apk --dart-define=API_BASE_URL=<url>
   ```

### Why those flags

`--memory 2Gi` matters most. PyTorch plus the checkpoints does not fit in
512MB: on a 512MB instance a 75-frame request was killed outright and the
service returned 502 for several minutes afterwards. Sentence requests can
carry up to 150 frames (about 7MB), so they need the headroom even more.

`--region asia-southeast1` is Singapore. Serving Thai users from Virginia adds
roughly a couple hundred milliseconds of round trip on every prediction, so
picking the nearest region is free latency.

`--cpu 2` is the other half of the latency story. Measured on a 0.1 CPU
instance, a prediction took 3 to 4 seconds regardless of how few frames were
sent, so processor share, not payload size, is the dominant cost.

### Cold starts

With no minimum instance count the service scales to zero and the first request
after an idle period has to start the container, which is slow for an image
this size. Keeping a warm instance (`--min-instances 1`) removes that delay but
is not covered by the free allowance.

## Running locally

```
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000
```

Then point the app at your machine's LAN address, since `localhost` on a phone
means the phone itself:

```
flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8000
```
