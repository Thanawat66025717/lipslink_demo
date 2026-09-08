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

`--memory 2Gi` matters most. PyTorch plus both checkpoints does not fit in
512MB: on a 512MB instance a 75-frame request was killed outright and the
service returned 502 for several minutes afterwards.

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
