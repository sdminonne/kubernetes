# kubectl logs Command Architecture

## Overview

The `kubectl logs` command goes through three main components:
1. **kubectl** (client) - parses args and makes API request
2. **kube-apiserver** - proxies the request to the appropriate kubelet
3. **kubelet** - retrieves logs from the container runtime

## Detailed Server-Side Flow

### 1. API Server: Receiving the Request

When kubectl calls the logs endpoint, it hits:
- **Endpoint**: `/api/v1/namespaces/{namespace}/pods/{pod}/log`
- **Handler**: `LogREST.Get()` in `pkg/registry/core/pod/rest/log.go:81-116`

The `LogREST` struct handles the request:

```go
func (r *LogREST) Get(ctx context.Context, name string, opts runtime.Object) (runtime.Object, error) {
    logOpts, ok := opts.(*api.PodLogOptions)
    // ... validation ...

    // Get the kubelet URL to proxy to
    location, transport, err := pod.LogLocation(ctx, r.Store, r.KubeletConn, name, logOpts)

    // Return a LocationStreamer that proxies the request
    return &genericrest.LocationStreamer{
        Location:    location,
        Transport:   transport,
        ContentType: "text/plain",
        Flush:       logOpts.Follow,
        // ...
    }, nil
}
```

### 2. API Server: Building the Kubelet URL

The `LogLocation()` function in `pkg/registry/core/pod/strategy.go:605-671` constructs the kubelet endpoint:

```go
func LogLocation(...) (*url.URL, http.RoundTripper, error) {
    // Get the pod and validate container
    pod, err := getPod(ctx, getter, name)
    container, err := validateContainer(container, pod)

    // Get node connection info where pod is running
    nodeName := types.NodeName(pod.Spec.NodeName)
    nodeInfo, err := connInfo.GetConnectionInfo(ctx, nodeName)

    // Build URL with query parameters
    params := url.Values{}
    if opts.Follow { params.Add("follow", "true") }
    if opts.Previous { params.Add("previous", "true") }
    if opts.Timestamps { params.Add("timestamps", "true") }
    // ... more params ...

    // Construct the kubelet URL
    loc := &url.URL{
        Scheme:   nodeInfo.Scheme,
        Host:     net.JoinHostPort(nodeInfo.Hostname, nodeInfo.Port),
        Path:     fmt.Sprintf("/containerLogs/%s/%s/%s", pod.Namespace, pod.Name, container),
        RawQuery: params.Encode(),
    }

    return loc, nodeInfo.Transport, nil
}
```

The API server then **proxies** the request to the kubelet at:
`https://<node-ip>:10250/containerLogs/{namespace}/{podName}/{containerName}?follow=true&...`

### 3. Kubelet: Handling the Request

The kubelet registers the `/containerLogs` endpoint in `pkg/kubelet/server/server.go:593-596`:

```go
ws.Route(ws.GET("/{podNamespace}/{podID}/{containerName}").
    To(s.getContainerLogs).
    Operation("getContainerLogs"))
```

The `getContainerLogs` handler (line 738-842):

```go
func (s *Server) getContainerLogs(request *restful.Request, response *restful.Response) {
    podNamespace := request.PathParameter("podNamespace")
    podID := request.PathParameter("podID")
    containerName := request.PathParameter("containerName")

    // Parse query parameters into PodLogOptions
    logOptions := &v1.PodLogOptions{}
    // ... decode and validate ...

    // Get pod and validate container exists
    pod, ok := s.host.GetPodByName(podNamespace, podID)

    // Set up output streams (stdout/stderr)
    stdout, stderr := fw, fw  // or separate based on Stream option

    response.Header().Set("Transfer-Encoding", "chunked")

    // Call kubelet's GetKubeletContainerLogs
    err := s.host.GetKubeletContainerLogs(ctx, kubecontainer.GetPodFullName(pod),
                                          containerName, logOptions, stdout, stderr)
}
```

### 4. Kubelet: Retrieving Logs from Container Runtime

The `GetKubeletContainerLogs()` method in `pkg/kubelet/kubelet_pods.go:1579-1636`:

```go
func (kl *Kubelet) GetKubeletContainerLogs(ctx context.Context, podFullName, containerName string,
                                           logOptions *v1.PodLogOptions, stdout, stderr io.Writer) error {
    // Parse pod name and get pod object
    name, namespace, err := kubecontainer.ParsePodFullName(podFullName)
    pod, ok := kl.GetPodByName(namespace, name)

    // Get container ID from pod status
    containerID, err := kl.validateContainerLogStatus(pod.Name, &podStatus, containerName, logOptions.Previous)

    // Delegate to the container runtime (containerd, CRI-O, etc.)
    return kl.containerRuntime.GetContainerLogs(ctx, pod, containerID, logOptions, stdout, stderr)
}
```

### 5. Container Runtime: Reading Actual Log Files

The `containerRuntime.GetContainerLogs()` (CRI implementation) reads logs from:
- Container runtime's log files (usually in `/var/log/pods/` or `/var/log/containers/`)
- Streams them back through the kubelet HTTP response
- The kubelet uses chunked transfer encoding for streaming

## Request Flow Diagram

```
kubectl logs mypod
    ↓
    → API Server: GET /api/v1/namespaces/default/pods/mypod/log
         ↓
         → Looks up which node hosts the pod
         → Proxies to: https://<node>:10250/containerLogs/default/mypod/container-name
              ↓
              → Kubelet receives request
              → Validates pod/container
              → Calls containerRuntime.GetContainerLogs()
                   ↓
                   → Container runtime (containerd/CRI-O)
                   → Reads log files from disk
                   → Streams back via HTTP chunked encoding
              ←
         ←
    ←
kubectl displays logs
```

## Key Files

- **kubectl**: `staging/src/k8s.io/kubectl/pkg/cmd/logs/logs.go`
- **API Server log endpoint**: `pkg/registry/core/pod/rest/log.go:81-116`
- **API Server proxy logic**: `pkg/registry/core/pod/strategy.go:605-671`
- **Kubelet HTTP handler**: `pkg/kubelet/server/server.go:738-842`
- **Kubelet log retrieval**: `pkg/kubelet/kubelet_pods.go:1579-1636`

## Supported Options

The `PodLogOptions` struct supports various parameters:
- `follow` - Stream logs continuously (like `tail -f`)
- `previous` - Get logs from a previous container instance (if it crashed/restarted)
- `timestamps` - Include timestamp with each log line
- `sinceSeconds` - Show logs since N seconds ago
- `sinceTime` - Show logs since a specific time
- `tailLines` - Number of lines to show from the end (like `tail -n`)
- `limitBytes` - Maximum number of bytes to return
- `stream` - Select stdout, stderr, or both (with `PodLogsQuerySplitStreams` feature gate)

## Architecture Highlights

1. **API Server as Proxy**: The API server doesn't handle logs directly—it proxies the request to the kubelet on the node where the pod is running.

2. **Streaming Support**: Uses HTTP chunked transfer encoding to stream logs in real-time when `follow=true`.

3. **Container Runtime Abstraction**: The kubelet uses the CRI (Container Runtime Interface) to retrieve logs, making it runtime-agnostic (works with containerd, CRI-O, Docker, etc.).

4. **Node Location**: The API server must look up which node hosts the pod (via `pod.Spec.NodeName`) before it can proxy the request.

5. **Authentication**: The API server uses its kubelet client certificates to authenticate with the kubelet's HTTPS endpoint (typically on port 10250).
