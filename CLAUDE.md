# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

### Building Kubernetes

```bash
# Build all binaries (Linux only by default)
make

# Build specific component
make WHAT=cmd/kubectl
make WHAT=cmd/kubelet

# Build with debug symbols (for use with debuggers like delve)
make DBG=1

# Build for specific platform
make WHAT=cmd/kubectl KUBE_BUILD_PLATFORMS=darwin/amd64
```

### Building in Docker Container

Kubernetes provides a containerized build environment for consistency:

```bash
# Build linux binaries in container
build/run.sh make

# Build all binaries for all platforms
build/run.sh make cross

# Build specific binary for specific platform
build/run.sh make kubectl KUBE_BUILD_PLATFORMS=darwin/amd64

# Drop into bash shell in build container
build/shell.sh
```

### Quick Releases

```bash
# Build release (runs tests, builds images)
make release

# Build release without tests (faster)
make quick-release

# Build release images (linux/amd64 only, faster)
make quick-release-images

# Build release images (all platforms)
make release-images
```

## Testing

### Unit Tests

```bash
# Run all unit tests
make test

# Run tests for specific package(s)
make test WHAT=./pkg/kubelet
make test WHAT=./pkg/scheduler

# Run tests with coverage
KUBE_COVER=y make test WHAT=./pkg/kubelet

# Run tests with specific flags
make test WHAT=./pkg/kubelet GOFLAGS=-v
```

### Integration Tests

```bash
# Run all integration tests
make test-integration

# Run specific integration test
make test-integration WHAT=./test/integration/kubelet

# Run specific test with coverage
make test-integration WHAT=./test/integration/pods GOFLAGS="-v -coverpkg=./pkg/kubelet/..." KUBE_COVER="y"

# Run specific test function by regex
make test-integration WHAT=./test/integration/pods KUBE_TEST_ARGS='-run ^TestPodUpdateActiveDeadlineSeconds$$'
```

### End-to-End Node Tests

```bash
# Build ginkgo first (required for e2e tests)
make ginkgo

# Run e2e node tests
make test-e2e-node

# Run with specific focus
make test-e2e-node FOCUS=Kubelet SKIP=container

# Run on remote host
make test-e2e-node REMOTE=true DELETE_INSTANCES=true
```

### Command-Line Tests

```bash
# Run all CLI tests
make test-cmd

# Run specific CLI tests
make test-cmd WHAT="deployment impersonation"
```

## Code Quality and Verification

### Pre-submission Verification

**Always run before submitting a PR:**

```bash
# Run all verification checks
make verify

# Run quick verification (skips slow checks)
make quick-verify

# Run specific verification
make verify WHAT="gofmt typecheck"
```

### Linting

```bash
# Run golangci-lint
make lint
```

### Code Generation and Updates

If verification fails, run the corresponding update script:

```bash
# Run all update scripts (fixes most verification failures)
make update

# Update vendor dependencies
hack/update-vendor.sh

# Update generated code (API types, conversions, etc.)
hack/update-codegen.sh

# Update go formatting
hack/update-gofmt.sh

# Update OpenAPI spec
hack/update-openapi-spec.sh

# Update mocks
hack/update-mocks.sh
```

## Development Workflow

1. **Make changes** to code
2. **Run unit tests** for affected packages: `make test WHAT=./pkg/...`
3. **Update generated code** if needed: `make update` or specific `hack/update-*.sh`
4. **Run verification**: `make verify` (or `make quick-verify` for faster feedback)
5. **Fix any issues** reported by verification
6. **Commit changes** following conventional commit style

## Repository Structure

### Core Directories

- **`cmd/`**: Entry points for Kubernetes binaries (kubelet, kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, kubectl, kubeadm)
- **`pkg/`**: Core Kubernetes packages organized by component
  - `pkg/api/`: API definitions and helpers
  - `pkg/apis/`: Internal API types and versioned APIs
  - `pkg/controller/`: Controller implementations (deployment, job, replicaset, etc.)
  - `pkg/kubelet/`: Kubelet implementation
  - `pkg/scheduler/`: Scheduler implementation
  - `pkg/proxy/`: Kube-proxy implementation
  - `pkg/registry/`: API server storage/registry implementations for each resource type
  - `pkg/volume/`: Volume plugin implementations
- **`staging/src/k8s.io/`**: Staged repositories that are published separately (client-go, apimachinery, api, apiserver, etc.)
- **`vendor/`**: Vendored dependencies
- **`test/`**: Tests organized by type
  - `test/e2e/`: End-to-end tests
  - `test/e2e_node/`: Node-specific end-to-end tests
  - `test/integration/`: Integration tests
  - `test/cmd/`: Command-line tests
- **`api/`**: API definitions, discovery, and OpenAPI specs
- **`hack/`**: Build and development scripts
- **`build/`**: Build system and Docker-based build environment

### Staging Repositories

The `staging/src/k8s.io/` directory contains code that is published to separate repositories. Imports of these packages resolve to the staging directory via Go workspace and module replace statements. Key staged repos:
- `k8s.io/client-go`: Kubernetes client library
- `k8s.io/apimachinery`: API machinery (scheme, types, meta)
- `k8s.io/api`: Kubernetes API types
- `k8s.io/apiserver`: Generic API server library
- `k8s.io/kubectl`: kubectl libraries
- `k8s.io/component-base`: Shared component utilities

## Architecture Overview

### API Server Architecture

The kube-apiserver (`cmd/kube-apiserver`) serves the Kubernetes API. Key components:
- **Registry**: Storage layer implementations in `pkg/registry/` for each API group/resource
- **API Machinery**: Generic API server framework from `staging/src/k8s.io/apiserver`
- **Admission**: Admission control plugins in `pkg/kubeapiserver/admission/`
- **Authentication/Authorization**: In `pkg/auth/` and staged `k8s.io/apiserver`

### Controller Pattern

Controllers in `pkg/controller/` follow the controller pattern:
- Watch resources via informers (from client-go)
- Process events through work queues
- Reconcile desired state vs actual state
- Update status and/or make changes to achieve desired state

Example controllers: deployment, job, replicaset, daemonset, statefulset, namespace, serviceaccount, garbagecollector.

### Kubelet Architecture

The kubelet (`pkg/kubelet/`) runs on each node:
- **Pod Lifecycle**: Pod management and status updates
- **Container Runtime**: Interfaces with container runtimes via CRI (`staging/src/k8s.io/cri-api`)
- **Volume Management**: Volume plugins in `pkg/volume/`
- **Probes**: Liveness, readiness, startup probes in `pkg/probe/`

### Scheduler Architecture

The kube-scheduler (`pkg/scheduler/`) schedules pods to nodes:
- **Framework**: Scheduling framework with extension points
- **Plugins**: Scheduling plugins for filtering and scoring
- **Queue**: Priority queue for pod scheduling

## Go Version and Modules

- **Go Version**: Specified in `.go-version` file (currently 1.25.4)
- **Go Workspace**: Uses `go.work` to manage staging repositories
- **Module Structure**: Main module at root plus staged modules in `staging/src/k8s.io/`

## Important Build Artifacts

Build outputs go to `_output/`:
- `_output/bin/`: Compiled binaries
- `_output/release-images/`: Docker images (as tar files)
- `_output/release-stage/`: Staged release files
- `_output/release-tars/`: Release tarballs

To load a Docker image: `docker load --input _output/release-images/amd64/kube-apiserver.tar`

## Common Patterns

### Running Single Test

```bash
# Unit test
make test WHAT=./pkg/kubelet GOFLAGS="-v -run TestSpecificFunction"

# Integration test
make test-integration WHAT=./test/integration/apiserver KUBE_TEST_ARGS='-run ^TestSpecificIntegration$$'
```

### Testing Local Changes

```bash
# Quick iteration cycle
make WHAT=cmd/kubectl           # Build binary
./_output/bin/kubectl version   # Test locally
make test WHAT=./pkg/kubectl    # Run unit tests
make verify WHAT=gofmt          # Check formatting
```

### Code Generation

Kubernetes uses extensive code generation. After modifying API types or adding new types:
1. Run `hack/update-codegen.sh` to regenerate:
   - Deepcopy methods
   - Defaulting functions
   - Conversions
   - OpenAPI definitions
2. Run `make verify` to ensure all generated code is up-to-date

### Working with Staged Repositories

When importing from staged repos (e.g., `k8s.io/client-go`), the import resolves to `staging/src/k8s.io/client-go`. Make changes directly in the staging directory. Never edit `go.mod` or `go.sum` in staged repos manually; use `hack/update-vendor.sh` instead.
