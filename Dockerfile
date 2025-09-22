# syntax=docker/dockerfile:1.4
# Copyright 2021 Synology Inc.

############## Build stage ##############
FROM golang:1.21.4-alpine as builder

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
		nfs-utils \
		open-iscsi \
		iproute2 \
		util-linux \
		xfsprogs \
		xfsprogs-extra
EOF

# Create symbolic link for nsenter.sh
WORKDIR /
COPY --chmod=777 <<-"EOF" /csibin/nsenter.sh
	#!/usr/bin/env bash
	iscsid_pid=$(pgrep iscsid | head -n 1)
	if [ -z "$iscsid_pid" ]; then
		echo "Error: iscsid process not found" >&2
		exit 1
	fi
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

# Create entrypoint script that starts iscsid before the CSI driver
COPY --chmod=755 <<-"EOF" /entrypoint.sh
	#!/bin/bash
	set -e

	# Check if we're running as a node pod (node pods have --nodeid with actual node name, not "NotUsed")
	if [[ "$*" == *"--nodeid"* ]] && [[ "$*" != *"--nodeid=NotUsed"* ]]; then
		echo "Detected node pod - initializing iSCSI daemon..."
		
		# Create necessary directories for iscsid
		mkdir -p /etc/iscsi
		mkdir -p /var/lib/iscsi/nodes
		mkdir -p /var/lib/iscsi/send_targets
		mkdir -p /var/lib/iscsi/static
		mkdir -p /var/lib/iscsi/isns
		mkdir -p /var/lib/iscsi/slp
		mkdir -p /var/lock/iscsi

		# Create basic iscsid configuration if it doesn't exist
		if [ ! -f /etc/iscsi/iscsid.conf ]; then
			echo "Creating basic iscsid.conf..."
			cat > /etc/iscsi/iscsid.conf << 'ISCSICONF'
# Basic iscsid configuration
iscsid.startup = /etc/rc.d/init.d/iscsid force-start
iscsid.safe_logout = Yes
node.startup = automatic
node.leading_login = No
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
node.session.timeo.replacement_timeout = 120
node.session.err_timeo.abort_timeout = 15
node.session.err_timeo.lu_reset_timeout = 30
node.session.err_timeo.tgt_reset_timeout = 30
node.session.initial_login_retry_max = 8
node.session.cmds_max = 128
node.session.queue_depth = 32
node.session.xmit_thread_priority = -20
node.session.iscsi.InitialR2T = No
node.session.iscsi.ImmediateData = Yes
node.session.iscsi.FirstBurstLength = 262144
node.session.iscsi.MaxBurstLength = 16776192
node.conn[0].iscsi.MaxRecvDataSegmentLength = 262144
node.conn[0].iscsi.MaxXmitDataSegmentLength = 0
discovery.sendtargets.iscsi.MaxRecvDataSegmentLength = 32768
node.conn[0].iscsi.HeaderDigest = None
node.session.nr_sessions = 1
node.session.iscsi.FastAbort = Yes
ISCSICONF
		fi

		# Start iscsid daemon in background
		echo "Starting iscsid daemon..."
		if /usr/sbin/iscsid -d 8 -f &
		then
			ISCSID_PID=$!
			echo "iscsid started with PID $ISCSID_PID"
			
			# Wait a moment for iscsid to initialize
			sleep 2
			
			# Verify iscsid is still running
			if kill -0 $ISCSID_PID 2>/dev/null; then
				echo "iscsid daemon started successfully"
			else
				echo "Error: iscsid daemon failed to start properly"
				exit 1
			fi
		else
			echo "Error: Failed to start iscsid daemon"
			exit 1
		fi
	else
		echo "Detected controller pod - skipping iSCSI daemon initialization"
	fi

	# Start the main CSI driver
	echo "Starting Synology CSI driver..."
	exec /synology-csi-driver "$@"
EOF

ENTRYPOINT ["/entrypoint.sh"]
