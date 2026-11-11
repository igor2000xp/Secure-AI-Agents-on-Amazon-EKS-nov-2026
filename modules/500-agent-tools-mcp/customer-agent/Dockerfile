FROM public.ecr.aws/docker/library/python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Pre-download the ONNX model into /app/.fastembed_cache so pods don't hit
# HuggingFace on startup. rag_tools.py reads from this exact path.
RUN python -c "from fastembed import TextEmbedding; TextEmbedding(model_name='sentence-transformers/all-MiniLM-L6-v2', cache_dir='/app/.fastembed_cache')"

FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /app/.fastembed_cache /app/.fastembed_cache
COPY agent.py rag_tools.py server.py ./

EXPOSE 8080
# Select the OTLP-HTTP exporter (opentelemetry-exporter-otlp-proto-http). The
# distro defaults OTEL_TRACES_EXPORTER=otlp with the gRPC exporter, which we do
# NOT install — without this the launcher crashes ("otlp_proto_grpc not found").
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
# opentelemetry-instrument auto-instruments httpx (outbound traceparent) and
# FastAPI (inbound span) with no code changes. The launcher binary comes from
# the builder stage's /usr/local/bin (copied above). See requirements.txt.
CMD ["opentelemetry-instrument", "python", "server.py"]
