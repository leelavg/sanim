# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Project Overview

**sanim** is a zero-dependency Bash generator for iSCSI block storage on Kubernetes/OpenShift. It uses StatefulSets as targets and DaemonSets as initiators, with sessions managed by the host kernel (not containers) for persistence across pod restarts.

## Core Principles

1. **Zero Dependencies**: Pure Bash only. No kubectl, jq, or external tools.
2. **Host Kernel Integration**: Use `nsenter` for host's iscsiadm. Sessions persist in host kernel, not containers.
3. **Script Externalization**: Keep entrypoint scripts in `scripts/` directory.

`summary.txt` will updated occasionally, like a changelog, look at it when you ONLY need more info.

This project uses a CLI ticket system for task management. Run `tk help` to know more and use it for maximum efficiency in tracking work.

DO NOT CHATTER, MAXIMUM CONCENTRATION ON THE SPECIFIC TASK, CHALLENGE OR ASK THE DESIGN, REACH TO A TRUSTED SOLUTION, TRUST BUT VERIFY THE SOLUTION IN CHUNKS.

When updating documentation (README, summary.txt, etc), focus on OUTCOMES and FINISHED PRODUCTS, not implementation details or debugging steps. Document what was built and what it does, not how bugs were fixed during development.
