# Clean boxes for ./selftest.sh. Two targets:
#   bare  git + python3 + bash and nothing else the pipeline lists: no bd, jq, rg, ss.
#         Exercises the installer's "required command absent" exit and every optional fallback.
#   full  bare + bd (official installer, latest release) + jq + ripgrep + iproute2 + bd-memgraph.
#         Exercises bd init, the hooks, the memory-graph stanza and the whole suite.
# Built and run by test/selftest-in-container.sh; nothing here is installed anywhere.
FROM ubuntu:24.04 AS bare
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
# The installer writes ~/.bashrc and the suites write under $HOME; a non-root user is the real case.
RUN useradd -m -s /bin/bash tester
USER tester
WORKDIR /home/tester
ENV HOME=/home/tester PATH=/home/tester/.local/bin:/usr/local/bin:/usr/bin:/bin
RUN git config --global user.email tester@example.invalid \
 && git config --global user.name tester \
 && git config --global init.defaultBranch main

FROM bare AS full
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq ripgrep iproute2 \
 && rm -rf /var/lib/apt/lists/*
USER tester
# bd: the official installer, as the README tells a new user to run it. BD_VERSION pins a release
# when the installer honours it; otherwise latest.
ARG BD_VERSION=
RUN curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | BD_VERSION="$BD_VERSION" bash \
 && bd --version
# bd-memgraph: optional; one python file plus a symlink on PATH.
ARG MEMGRAPH_REPO=https://github.com/scgoetsch/bd-memgraph
RUN git clone --depth 1 "$MEMGRAPH_REPO" /home/tester/bd-memgraph \
 && ln -s /home/tester/bd-memgraph/bd-memgraph.py /home/tester/.local/bin/bd-memgraph \
 && bd-memgraph --help >/dev/null
