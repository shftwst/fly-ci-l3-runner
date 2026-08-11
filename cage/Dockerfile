# The cage. A normal container, run inside the fly Machine's own docker engine, so
# faff's admission gate reads it as contained (via /.dockerenv) with no host socket.
# It carries everything one L3 drain needs: the harness, git tooling, and faff.
#
# Layers are deliberately collapsed: the Machine's docker engine runs on the vfs storage
# driver (a microVM has no kernel overlay), and vfs copies the WHOLE filesystem on every
# layer commit, so each extra RUN adds minutes to the one-time cage build. Fewer, fatter
# layers = a much faster boot.
FROM node:22-bookworm-slim

# Root layer: system tools + the harness, then a non-root user for the drain.
# openssh-client is not incidental: it provides ssh-keygen, which git needs for SSH
# commit signing (gpg.format=ssh) and verify-commit. --no-install-recommends omits it
# otherwise. Keep it if commits must be GitHub-Verified.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl util-linux coreutils gh openssh-client \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
    && useradd -m -s /bin/bash faff \
    && rm -rf /var/lib/apt/lists/*

USER faff
WORKDIR /home/faff

# Mount point for the persistent state volume (faff's gitignored resume store + run-dirs).
# Created faff-owned so the named volume, when first mounted here, inherits faff ownership
# (docker seeds a fresh volume from the image path's perms) and drain.sh can write to it.
RUN mkdir -p /home/faff/state

# faff-user layer: install faff via its plugin marketplace (the supported consumer path,
# not the repo's dev-only link-skills), and register the hosted Linear MCP that faff's
# skills call by name. The MCP is OAuth; drain.sh supplies the carried mcpOAuth token at
# runtime so it connects headlessly.
RUN claude plugin marketplace add shftwst/faff \
    && claude plugin install faff@faff \
    && claude mcp add --transport http --scope user linear https://mcp.linear.app/mcp

# drain.sh is already executable in the Machine's /cage build context, and the legacy
# builder preserves the mode, so no separate chmod layer is needed.
COPY --chown=faff:faff drain.sh /home/faff/drain.sh
ENTRYPOINT ["/home/faff/drain.sh"]
