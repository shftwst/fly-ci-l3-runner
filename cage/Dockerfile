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

# Install faff the way a consumer does: add its marketplace and install the plugin.
# This is the supported install (not the repo's dev-only link-skills script). Bump it
# later with `claude plugin update faff@faff`, or pin by installing a tagged version.
RUN claude plugin marketplace add shftwst/faff \
    && claude plugin install faff@faff

# Register the Linear tracker MCP: the hosted server faff's skills call by name. It is
# OAuth-authenticated, so registration alone leaves it "needs authentication"; drain.sh
# supplies the carried credentials at runtime so it connects headlessly.
RUN claude mcp add --transport http --scope user linear https://mcp.linear.app/mcp

COPY --chown=faff:faff drain.sh /home/faff/drain.sh
RUN chmod +x /home/faff/drain.sh
ENTRYPOINT ["/home/faff/drain.sh"]
