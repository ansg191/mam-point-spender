FROM gcr.io/distroless/static-debian13:nonroot

ARG TARGETPLATFORM

COPY --chown=nonroot:nonroot $TARGETPLATFORM/mam-point-spender /usr/local/bin/mam-point-spender

ENTRYPOINT ["/usr/local/bin/mam-point-spender"]
