"""AnyCompany Shop — sample service.

A deliberately tiny FastAPI app. File an issue describing a change (e.g. "add
promo-code checkout") and label it `agent`; the autonomous coding agent
implements it in an isolated sandbox and opens a PR.
"""

from fastapi import FastAPI

app = FastAPI(title="AnyCompany Sample App")


@app.get("/")
def root() -> dict:
    return {"service": "sample-app", "message": "Hello from AnyCompany Shop"}
