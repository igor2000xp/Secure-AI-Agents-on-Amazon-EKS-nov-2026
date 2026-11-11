# Sandbox runtime image: sandboxd + the Python analysis toolchain.
#
# Built FROM the upstream sandboxd image, pulled straight from registry.k8s.io.
# It is a BUILD-time base, so the pull happens in CodeBuild (or on the IDE for a
# manual rebuild), never on a cluster node — the image the sandboxes actually run
# is this derived one, which lives in ECR. This is upstream's
# recommended "topology A": sandboxd IS the execution environment, so commands
# the agent-sandbox MCP server runs over sandboxd's gRPC ProcessService execute
# in THIS image's filesystem. Whatever the generated analysis code imports has
# to be installed here — a neighbouring container's tools are not reachable,
# because a shared volume shares files, not binaries.
#
# The ARG has a DEFAULT so `docker build` works with no arguments, while
# codebuild-images.tf still overrides it from the agent-sandbox version in
# manifests/vendor/sources.yaml — which stays the single source of truth for the
# provisioned path. Keep this default in step with that file when bumping.
ARG SANDBOXD_IMAGE=registry.k8s.io/agent-sandbox/sandboxd:v1.0.10
FROM ${SANDBOXD_IMAGE}

# The base image runs as UID 1000 (sandboxd's non-root runtime user); drop to
# root only for the install, then go back.
USER root

# Python from Debian's archive rather than pip. The sandboxd base is
# debian:bookworm-slim, which ships no Python at all, and its system Python
# would be PEP 668 "externally managed" — so a pip install would need either
# --break-system-packages or a venv on PATH for every exec'd command. The
# distro packages avoid both, and avoid compiling pandas/matplotlib from source
# when a wheel is missing.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pandas \
        python3-matplotlib \
        python3-tabulate \
    && rm -rf /var/lib/apt/lists/*

# matplotlib renders headlessly: the micro-VM has no display server, so force
# the non-interactive Agg backend.
ENV MPLBACKEND=Agg
# UID 1000 has no writable home, so matplotlib's default cache path resolves to
# a root-owned /.config/matplotlib and it warns on every import. That warning
# goes to stderr, and stderr comes back through the MCP tool result into the
# model's context — so point it somewhere writable.
ENV MPLCONFIGDIR=/tmp/matplotlib

USER 1000

# ENTRYPOINT and WORKDIR are inherited from the sandboxd base deliberately:
# /usr/local/bin/sandboxd serving REST on :8080 and gRPC on :9090, rooted at
# /workspace. Overriding either would leave the MCP server with nothing to talk
# to. There is no uvicorn server here any more — the FastAPI app on :8888 that
# this image used to run was replaced by sandboxd.
