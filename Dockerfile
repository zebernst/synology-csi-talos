# syntax=docker/dockerfile:1.4
# Copyright 2021 Synology Inc.

############## Build stage ##############
FROM golang:1.20.3-alpine as builder

RUN apk add --no-cache alpine-sdk
WORKDIR /go/src/synok8scsiplugin
COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
COPY pkg ./pkg

ARG TARGETPLATFORM
ENV CGO_ENABLED=0 GOOS=linux
RUN GOARCH=$(echo "$TARGETPLATFORM" | cut -f2 -d/) \
    GOARM=$(echo "$TARGETPLATFORM" | cut -f3 -d/ | cut -c2-) \
    go build -v -ldflags '-extldflags "-static"' -o ./synology-csi-driver .

############## Final stage ##############
FROM alpine:latest as driver
LABEL maintainers="Synology Authors" \
      description="Synology CSI Plugin"

RUN <<-EOF 
	apk add --no-cache \
		bash \
		blkid \
		btrfs-progs \
		ca-certificates \
		cifs-utils \
		e2fsprogs \
		e2fsprogs-extra \
		iproute2 \
		util-linux \
		xfsprogs \
		xfsprogs-extra
EOF

# Create symbolic link for nsenter.sh
WORKDIR /
COPY --chmod=777 <<-"EOF" /csibin/nsenter.sh
	#!/usr/bin/env bash
	iscsid_pid=$(pgrep iscsid)
	BIN="$(basename "$0")"
	nsenter --mount="/proc/${iscsid_pid}/ns/mnt" --net="/proc/${iscsid_pid}/ns/net" -- "$BIN" "$@"
EOF
RUN <<-EOT
	ln -s /csibin/nsenter.sh /csibin/iscsiadm
	ln -s /csibin/nsenter.sh /csibin/multipath
	ln -s /csibin/nsenter.sh /csibin/multipathd
EOT

ENV PATH="/csibin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Copy and run CSI driver
COPY --from=builder /go/src/synok8scsiplugin/synology-csi-driver /synology-csi-driver

ENTRYPOINT ["/synology-csi-driver"]
