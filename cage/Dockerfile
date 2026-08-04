# The cage. A normal container, run inside the fly Machine's own docker engine, so
# faff's admission gate reads it as contained (via /.dockerenv) with no host socket.
# It carries everything one L3 drain needs: the harness, git tooling, and faff.
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl util-linux coreutils gh \
    && rm -rf /var/lib/apt/lists/*

# The harness. Swap this line if you drive a different one.
RUN npm install -g @anthropic-ai/claude-code

# A non-root user for the drain.
RUN useradd -m -s /bin/bash faff
USER faff
WORKDIR /home/faff

# faff tooling: its skills plus the faff CLI, linked for this user.
RUN git clone --depth 1 https://github.com/shftwst/faff.git /home/faff/faff \
    && bash /home/faff/faff/scripts/link-skills.sh --global
ENV PATH="/home/faff/.local/bin:${PATH}"

COPY --chown=faff:faff drain.sh /home/faff/drain.sh
RUN chmod +x /home/faff/drain.sh
ENTRYPOINT ["/home/faff/drain.sh"]
