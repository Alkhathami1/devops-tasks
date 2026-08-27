# Pinned by tag AND digest so a rebuild months from now resolves the identical
# base image. A floating tag would silently change the runtime underneath the
# evidence captured in the report.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32

ENV NODE_ENV=production

WORKDIR /app

# Dependencies are installed in their own layer so application edits do not
# invalidate the npm cache on every rebuild.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

# wget is used by the container healthcheck. It ships with the alpine base, so
# nothing extra is installed for it.
HEALTHCHECK --interval=5s --timeout=3s --start-period=20s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1

# Drop privileges. The node image already provides an unprivileged `node` user.
USER node

EXPOSE 3000

# Exec form, and NOT wrapped in an init/shell. This makes the node process PID 1
# inside the container, which is what allows the RAM-exhaustion drill to produce
# a genuine OOMKilled: true — a shell or init as PID 1 would absorb the kill of
# its child and the container would survive.
CMD ["node", "src/server.js"]
