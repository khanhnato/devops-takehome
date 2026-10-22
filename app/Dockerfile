# syntax=docker/dockerfile:1

# --- build stage: compile a static binary on the build host's native arch,
# cross-compiling for the target arch (no QEMU needed for multi-arch builds).
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/quote-api .

# --- runtime stage: distroless static, no shell, no package manager.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/quote-api /quote-api
# 65532 = "nonroot" in distroless; numeric so runAsNonRoot can verify it.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/quote-api"]
