# Binary is built on the host (CGO_ENABLED=0 GOOS=linux) by build-and-deploy.sh
# so no golang base image is needed.
FROM scratch
COPY webhook /webhook
ENTRYPOINT ["/webhook"]
