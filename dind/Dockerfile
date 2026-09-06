# Source of truth for mill's sidecar; Dependabot reviews base-image updates.
FROM docker:29.8.0-dind@sha256:5efed980cba3fc126cf54e21a5a6ff8849d05b6e0623d6e7612f48e9cd6cd17e

# Docker's static bundle can lag fixes available in Alpine's maintained
# packages. Replace the bundled copies so PATH and plugin discovery use the
# patched packages, and update the base OS packages in the same layer.
RUN apk upgrade --no-cache \
    && apk add --no-cache containerd runc docker-cli-buildx \
    && rm -f /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 \
        /usr/local/bin/ctr /usr/local/bin/runc \
        /usr/local/libexec/docker/cli-plugins/docker-buildx
