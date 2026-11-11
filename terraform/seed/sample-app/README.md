# sample-app

A tiny FastAPI service for **AnyCompany Shop**, used by the autonomous coding
agent lab (module 1000). It's intentionally minimal so a single feature request
is a clear, self-contained change.

## Try the agent

1. Open an issue describing a small change, e.g. **"Add promo-code checkout: a
   `POST /checkout` that applies codes like `SAVE10` or `FREESHIP` to a subtotal"**.
2. Add the **`agent`** label.
3. The coding agent implements it in an isolated sandbox and opens a PR back on
   the issue.

## Run locally

```bash
pip install -r requirements.txt
uvicorn app:app --reload   # serves on http://127.0.0.1:8000
pytest                     # run the tests
```
