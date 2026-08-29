# Universal Pi-hole Deployer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a robust, idempotent, multi-topology Pi-hole installation and lifecycle management CLI for Linux systems.

**Architecture:** A self-contained, modular Bash utility with strict error handling, automatic kernel port tuning, systemd-resolved conflict resolution, and container/sidecar generation.

**Tech Stack:** Bash 5+, Podman / Docker, Tailscale Serve, Caddy (for standalone TLS), systemd, POSIX utilities.

**Spec:** [docs/superpowers/specs/2026-08-29-pihole-universal-deployer-design.md](file:///home/guptavi/Work/docs/superpowers/specs/2026-08-29-pihole-universal-deployer-design.md)

## Global Constraints
- Must be strictly idempotent (safe to run multiple times without state corruption).
- Must support Rootless Podman without requiring permanent root privileges.
- Must gracefully handle missing optional utilities.
- Must never overwrite existing `.env` credentials unless explicitly directed.

---

### Task 1: Comprehensive Automated Test Suite

**Files:**
- Create: `/home/guptavi/Work/tests/test_deployer.sh`

- [ ] **Step 1: Write the test harness**
```bash
#!/usr/bin/env bash
set -euo pipefail
# Test harness for pihole-deploy.sh
```

- [ ] **Step 2: Run test harness to verify test coverage**
Run: `bash /home/guptavi/Work/tests/test_deployer.sh`
Expected: PASS

---

### Task 2: Implement Core Script Modules & Rollback Support

**Files:**
- Modify: `/home/guptavi/Work/pihole-deploy.sh`

- [ ] **Step 1: Implement Uninstallation & Rollback Command**
- [ ] **Step 2: Implement Automated Port 53 Stub Detection**
- [ ] **Step 3: Implement Standalone, Container, and Sidecar Generators**
- [ ] **Step 4: Implement Healthcheck Verification Routine**
- [ ] **Step 5: Run full automated verification suite**
