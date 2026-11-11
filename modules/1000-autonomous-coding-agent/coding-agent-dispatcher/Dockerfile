# Coding-agent dispatcher. Long-running FastAPI service: receives Gitea webhooks,
# vends single-use coding micro-VMs via the Kubernetes API, drives Claude Code,
# and talks to the Gitea API. Base from the ECR public mirror (no docker.io).
FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY webhook.py gitea_client.py sandbox_runner.py server.py .
EXPOSE 8080
# This container's stdout IS the lab's viewing experience: watch-sandbox.sh
# tails it, and participants read the coding session from it live. So uvicorn is
# told to keep quiet and let the run be the content.
#
#   --no-access-log  drops one line per request. The readiness probe hits
#                    /healthz every few seconds, which otherwise scrolls the
#                    session off the screen on its own.
#   --log-level warning  drops uvicorn's startup banner ("Started server
#                    process", "Application startup complete", the bind line).
#                    Real problems still print, because they are warnings or
#                    errors.
#
# Our own logger stays at INFO (server.py's logging.basicConfig), so dispatcher
# lines and the relayed [issue-N] session output are unaffected.
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", \
     "--log-level", "warning", "--no-access-log"]
