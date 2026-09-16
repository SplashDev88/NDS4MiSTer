FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends make gcc g++ python3 flex bison bc libssl-dev libelf-dev libgmp-dev libmpfr-dev libmpc-dev xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
