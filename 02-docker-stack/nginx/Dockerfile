# Pinned by tag AND digest, as with the backend base image.
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

# The frontend and the reverse proxy live in one container, per the assignment's
# grouping of "frontend + reverse proxy".
COPY nginx.conf /etc/nginx/nginx.conf
COPY html/ /usr/share/nginx/html/

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/healthz || exit 1

EXPOSE 8080
