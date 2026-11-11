FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py tools.py server.py ./

EXPOSE 8080
# Unbuffered stdout so startup prints (e.g. "Langfuse connected successfully")
# reach `kubectl logs` immediately. Without this, Python block-buffers stdout
# when it is a pipe, and the long-lived server never flushes the startup line.
ENV PYTHONUNBUFFERED=1
# Select the OTLP-HTTP exporter (opentelemetry-exporter-otlp-proto-http). The
# distro defaults OTEL_TRACES_EXPORTER=otlp with the gRPC exporter, which we do
# NOT install — without this the launcher crashes ("otlp_proto_grpc not found").
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
# opentelemetry-instrument auto-instruments httpx (outbound traceparent) and
# FastAPI (inbound span) with no code changes. See requirements.txt.
CMD ["opentelemetry-instrument", "python", "server.py"]
