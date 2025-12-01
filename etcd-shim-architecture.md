# Kubernetes etcd Shim Architecture

## Overview

The "etcd shim" is a multi-layered storage architecture in Kubernetes that abstracts the etcd storage backend behind generic interfaces. Rather than being a single component, it consists of several layers that work together to provide a clean, performant, and secure interface between the API server and etcd.

### Key Responsibilities

- **Abstraction**: Decouples API server logic from the specific storage backend
- **Performance**: Provides in-memory caching for read operations
- **Security**: Handles encryption at rest transparently
- **Reliability**: Implements optimistic concurrency control and retries
- **Watch Support**: Efficiently streams resource changes to clients
- **Data Integrity**: Ensures consistency through resource versioning

---

## Architecture Overview

The etcd shim consists of multiple layers, each with specific responsibilities:

```
┌─────────────────────────────────────────────────────────────┐
│                    API Server Handler                       │
│                  (processes HTTP requests)                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              REST Storage (Registry Layer)                  │
│     Location: pkg/registry/<group>/<resource>/storage/      │
│     - Resource-specific business logic                      │
│     - Validation and defaulting                             │
│     - Strategy pattern for create/update/delete             │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   Cacher (Optional Layer)                   │
│     Location: staging/src/k8s.io/apiserver/pkg/             │
│               storage/cacher/cacher.go:261-342              │
│                                                             │
│     - In-memory cache of all resources of a type            │
│     - Serves GET/LIST from memory (fast path)               │
│     - Delegates writes to underlying storage                │
│     - Watches etcd and keeps cache synchronized             │
│     - Manages watch connections for clients                 │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              etcd3.store (storage.Interface)                │
│     Location: staging/src/k8s.io/apiserver/pkg/             │
│               storage/etcd3/store.go:80-100                 │
│                                                             │
│     - Implements generic storage.Interface                  │
│     - Handles encoding/decoding (protobuf/json)             │
│     - Manages encryption/decryption via Transformer         │
│     - Resource versioning via Versioner                     │
│     - Key prefixing for multi-tenancy                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│          kubernetes.Client (etcd Client Wrapper)            │
│     Location: vendor/go.etcd.io/etcd/client/v3/             │
│               kubernetes/                                   │
│                                                             │
│     - Kubernetes-specific operations                        │
│     - Optimistic locking primitives (OptimisticPut, etc.)   │
│     - Simplified interface over raw etcd                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                     etcd v3 Client                          │
│     Location: vendor/go.etcd.io/etcd/client/v3/             │
│                                                             │
│     - gRPC communication with etcd cluster                  │
│     - Range, Put, Delete, Watch, Txn operations             │
│     - Lease management                                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ etcd Cluster │
                    │   (storage)  │
                    └──────────────┘
```

---

## Core Components

### 1. Storage Interface

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/interfaces.go:169-279`

The `storage.Interface` is the core abstraction that defines all storage operations. It provides a consistent API regardless of the underlying storage backend.

**Key Methods**:

```go
type Interface interface {
    // Versioner returns the resource versioning implementation
    Versioner() Versioner

    // Create adds a new object at key with optional TTL
    Create(ctx context.Context, key string, obj, out runtime.Object, ttl uint64) error

    // Delete removes an object at key with optional preconditions
    Delete(ctx context.Context, key string, out runtime.Object,
           preconditions *Preconditions, validateDeletion ValidateObjectFunc,
           cachedExistingObject runtime.Object) error

    // Watch begins watching for changes at key
    Watch(ctx context.Context, key string, opts ListOptions) (watch.Interface, error)

    // Get retrieves a single object
    Get(ctx context.Context, key string, opts GetOptions, objPtr runtime.Object) error

    // GetList retrieves all objects matching the key prefix
    GetList(ctx context.Context, key string, opts ListOptions, listObj runtime.Object) error

    // GuaranteedUpdate provides atomic read-modify-write
    GuaranteedUpdate(ctx context.Context, key string, destination runtime.Object,
                     ignoreNotFound bool, preconditions *Preconditions,
                     tryUpdate UpdateFunc, cachedExistingObject runtime.Object) error

    // Count returns the number of objects matching key
    Count(key string) (int64, error)

    // Additional methods for request counts and storage encoding version
}
```

**Design Principles**:
- Backend agnostic - could theoretically support non-etcd backends
- Supports both individual operations and bulk list operations
- Includes precondition checking for optimistic concurrency
- Provides watch capability for reactive updates

### 2. etcd3 Store Implementation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:80-100`

The `store` struct implements `storage.Interface` for etcd v3:

```go
type store struct {
    client             *kubernetes.Client      // etcd client wrapper
    codec              runtime.Codec           // Serialization codec
    versioner          storage.Versioner       // Resource version handling
    transformer        value.Transformer       // Encryption/decryption
    pathPrefix         string                  // etcd key prefix
    groupResource      schema.GroupResource    // Resource type
    watcher            *watcher                // Watch implementation
    leaseManager       *leaseManager           // TTL management
    decoder            Decoder                 // Deserialization
    resourcePrefix     string                  // Resource-specific prefix
    newListFunc        func() runtime.Object   // List constructor
    compactor          Compactor               // Compaction management
}
```

**Responsibilities**:
- Translates generic storage operations to etcd operations
- Manages key prefixing: `/registry/<resource>/<namespace>/<name>`
- Handles serialization (JSON or Protobuf)
- Applies encryption transformation transparently
- Manages resource versioning using etcd revision numbers
- Coordinates watch operations

### 3. Watch Cache (Cacher)

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/cacher/cacher.go:261-342`

The `Cacher` wraps a storage.Interface and provides in-memory caching:

```go
type Cacher struct {
    // Underlying storage (typically etcd3.store)
    storage          storage.Interface

    // In-memory cache of all objects
    watchCache       *watchCache

    // Reflector keeps cache synchronized with storage
    reflector        *cache.Reflector

    // Event queue from reflector to cache
    incoming         chan watchCacheEvent

    // Active watch connections from API clients
    watchers         indexedWatchers

    // Resource versioning
    versioner        storage.Versioner

    // Additional fields for lifecycle and metrics
}
```

**Operation**:
1. **Initialization**: Lists all objects from etcd and populates cache
2. **Synchronization**: Reflector watches etcd and streams updates to cache
3. **Read Path**: GET/LIST operations served directly from memory
4. **Write Path**: CREATE/UPDATE/DELETE delegated to underlying storage
5. **Watch Distribution**: Maintains watch connections and filters events

**Benefits**:
- Dramatically reduces etcd load for read-heavy workloads
- Enables efficient in-process watches
- Supports filtering and indexing
- Provides consistent resource versions

### 4. Storage Factory

**Location**: `staging/src/k8s.io/apiserver/pkg/server/storage/storage_factory.go:65-90`

The `DefaultStorageFactory` constructs storage backends for different resource types:

```go
type DefaultStorageFactory struct {
    // Default storage configuration (etcd endpoints, credentials, etc.)
    StorageConfig             storagebackend.Config

    // Per-resource overrides (different etcd cluster, serialization, etc.)
    Overrides                 map[schema.GroupResource]groupResourceOverrides

    // etcd key prefixes for each resource
    DefaultResourcePrefixes   map[schema.GroupResource]string

    // Default serialization format
    DefaultMediaType          string

    // Codec factory
    DefaultSerializer         runtime.StorageSerializer

    // Configuration for encoding versions
    ResourceEncodingConfig    ResourceEncodingConfig
}
```

**Responsibilities**:
- Creates storage backends based on configuration
- Applies per-resource customization
- Wraps storage with cacher if enabled
- Manages encryption configuration
- Handles health checking

---

## Data Flow Diagrams

### GET Operation Flow

```
┌──────────┐
│  Client  │
└────┬─────┘
     │ GET /api/v1/namespaces/default/pods/nginx
     ▼
┌─────────────────┐
│  API Handler    │
└────┬────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  REST Storage (pkg/registry/core/pod/storage/)          │
│  - Validates request                                    │
│  - Applies defaults                                     │
└────┬────────────────────────────────────────────────────┘
     │ storage.Get(ctx, "/registry/pods/default/nginx", ...)
     ▼
┌─────────────────────────────────────────────────────────┐
│  Cacher (if enabled)                                    │
│  - Check in-memory cache                                │
│  - Return cached object (FAST PATH)                     │
│  - Or fallthrough to underlying storage (SLOW PATH)     │
└────┬────────────────────────────────────────────────────┘
     │ (if cache miss or disabled)
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd3.store                                            │
│  1. Prepare key: "/registry/pods/default/nginx"         │
│  2. Call: client.Kubernetes.Get(ctx, key)               │
│  3. Transform from storage (decrypt if encrypted)       │
│  4. Decode protobuf/JSON into Pod object                │
│  5. Set resource version from etcd revision             │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd Client                                            │
│  - gRPC Range request to etcd                           │
│  - Returns key-value with revision                      │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌──────────┐
│   etcd   │
└──────────┘
```

### CREATE Operation Flow

```
┌──────────┐
│  Client  │
└────┬─────┘
     │ POST /api/v1/namespaces/default/pods
     │ Body: Pod specification
     ▼
┌─────────────────────────────────────────────────────────┐
│  REST Storage (pkg/registry/core/pod/storage/)          │
│  1. Validate pod specification                          │
│  2. Apply defaults                                      │
│  3. Run admission controllers                           │
│  4. Generate name if needed                             │
└────┬────────────────────────────────────────────────────┘
     │ storage.Create(ctx, key, podObj, ...)
     ▼
┌─────────────────────────────────────────────────────────┐
│  Cacher (if enabled)                                    │
│  - Delegate to underlying storage (writes passthrough)  │
│  - Cache will be updated via watch event                │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd3.store.Create()                                   │
│  1. Clear resource version (new object)                 │
│  2. Encode object: runtime.Encode(codec, pod)           │
│  3. Get TTL lease if needed                             │
│  4. Transform to storage (encrypt if configured)        │
│  5. Optimistic create with revision=0                   │
│     client.Kubernetes.OptimisticPut(key, data, 0, ...)  │
│  6. Decode response into output object                  │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd Client (OptimisticPut)                            │
│  - Creates etcd transaction:                            │
│    IF key version == 0 (doesn't exist)                  │
│    THEN Put(key, value)                                 │
│    ELSE fail with AlreadyExists                         │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌──────────┐
│   etcd   │
│  - Store │
│  - Watch │
│    event │
└────┬─────┘
     │ Watch event: PUT /registry/pods/default/nginx
     ▼
┌─────────────────────────────────────────────────────────┐
│  Cacher (watch reflector)                               │
│  - Receive watch event                                  │
│  - Update in-memory cache                               │
│  - Notify all watching clients                          │
└─────────────────────────────────────────────────────────┘
```

### UPDATE Operation Flow (GuaranteedUpdate)

```
┌──────────┐
│  Client  │
└────┬─────┘
     │ PUT /api/v1/namespaces/default/pods/nginx
     ▼
┌─────────────────────────────────────────────────────────┐
│  REST Storage                                           │
│  - Parse updated object                                 │
│  - Validate changes                                     │
└────┬────────────────────────────────────────────────────┘
     │ storage.GuaranteedUpdate(ctx, key, out, tryUpdate, ...)
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd3.store.GuaranteedUpdate()                         │
│  START RETRY LOOP:                                      │
│                                                         │
│  1. Get current state:                                  │
│     - Read from etcd                                    │
│     - Decrypt and decode                                │
│     - Store current revision                            │
│                                                         │
│  2. Check preconditions:                                │
│     - UID matches (if specified)                        │
│     - ResourceVersion matches (if specified)            │
│                                                         │
│  3. Call user's tryUpdate function:                     │
│     - User modifies object in-place                     │
│     - Returns updated object + desired TTL              │
│                                                         │
│  4. Encode updated object                               │
│                                                         │
│  5. Short-circuit if no change:                         │
│     - Compare encoded bytes                             │
│     - Return early if identical                         │
│                                                         │
│  6. Transform to storage (encrypt)                      │
│                                                         │
│  7. Optimistic update:                                  │
│     client.Kubernetes.OptimisticPut(                    │
│         key, newData, currentRevision, ...)             │
│                                                         │
│  8. Check transaction result:                           │
│     - If succeeded: RETURN SUCCESS                      │
│     - If failed (concurrent modification): RETRY        │
│                                                         │
│  END RETRY LOOP                                         │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd Client (OptimisticPut)                            │
│  - Creates etcd transaction:                            │
│    IF key.ModRevision == currentRevision                │
│    THEN Put(key, value)                                 │
│    ELSE fail (return succeeded=false)                   │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌──────────┐
│   etcd   │
└──────────┘
```

**Key Points**:
- **Optimistic Concurrency**: No locks; uses etcd revision numbers
- **Automatic Retry**: Conflicts detected and retried transparently
- **User Function**: Business logic in `tryUpdate` function
- **Consistency**: User sees consistent object state in `tryUpdate`

### WATCH Operation Flow

```
┌──────────┐
│  Client  │
└────┬─────┘
     │ GET /api/v1/pods?watch=1&resourceVersion=1000
     ▼
┌─────────────────────────────────────────────────────────┐
│  API Handler                                            │
│  - Establish HTTP connection (chunked transfer)         │
└────┬────────────────────────────────────────────────────┘
     │ storage.Watch(ctx, key, opts)
     ▼
┌─────────────────────────────────────────────────────────┐
│  Cacher.Watch()                                         │
│  1. Determine start point:                              │
│     - If resourceVersion specified: start from there    │
│     - Else: start from current cache state              │
│                                                         │
│  2. Create cacheWatcher:                                │
│     - Buffered channel for events                       │
│     - Filter function for this watch                    │
│     - Field/label selectors                             │
│                                                         │
│  3. Register with indexedWatchers                       │
│                                                         │
│  4. Send initial events:                                │
│     - If starting from old version, replay from cache   │
│     - Send ADDED events for existing objects            │
│                                                         │
│  5. Stream ongoing events:                              │
│     - Filter events based on selectors                  │
│     - Apply transformation (Added/Modified/Deleted)     │
│     - Send over channel                                 │
└────┬────────────────────────────────────────────────────┘
     │
     │ (Cacher's reflector feeds events)
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd3.store.Watch()                                    │
│  1. Create watchChan with buffer                        │
│                                                         │
│  2. Start background goroutine:                         │
│     a. Sync initial state (if resourceVersion=0):       │
│        - List all objects                               │
│        - Send as ADDED events                           │
│                                                         │
│     b. Create etcd watch from revision:                 │
│        etcdWatch := client.Watch(ctx, key, revision)    │
│                                                         │
│     c. Stream events loop:                              │
│        - Receive from etcd watch channel                │
│        - Transform (decrypt, decode)                    │
│        - Determine event type (Added/Modified/Deleted)  │
│        - Apply filter if specified                      │
│        - Send to watchChan                              │
│                                                         │
│  3. Return watchChan to caller                          │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│  etcd Client.Watch()                                    │
│  - Establishes gRPC watch stream                        │
│  - Sends watch request with key prefix and revision     │
│  - Streams events as they occur                         │
└────┬────────────────────────────────────────────────────┘
     │
     ▼
┌──────────┐
│   etcd   │
│  - Watch │
│  - Send  │
│    events│
└──────────┘
```

**Watch Features**:
- **Starting Point**: Can start from any historical revision (within compaction window)
- **Bookmarks**: Periodic "heartbeat" events with current revision
- **Filtering**: Label selectors and field selectors applied in Cacher
- **Reliability**: Automatic reconnection and event replay
- **Efficiency**: Cacher allows many clients to watch without multiplying etcd load

---

## Key Operations Implementation Details

### 1. GET Operation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:238-271`

```go
func (s *store) Get(ctx context.Context, key string, opts storage.GetOptions,
                    out runtime.Object) error {
    // Prepare full etcd key with prefix
    preparedKey, err := s.prepareKey(key, false)
    if err != nil {
        return err
    }

    // Get from etcd
    getResp, err := s.client.Kubernetes.Get(ctx, preparedKey,
        kubernetes.GetOptions{
            Revision: opts.ResourceVersion,
        })
    if err != nil {
        return err
    }

    // Decrypt if encryption is enabled
    data, _, err := s.transformer.TransformFromStorage(ctx,
        getResp.KV.Value, authenticatedDataString(preparedKey))
    if err != nil {
        return storage.NewInternalError(err.Error())
    }

    // Decode into output object
    return s.decoder.Decode(data, out, getResp.KV.ModRevision)
}
```

**Flow**:
1. **Key Preparation**: Adds prefix (e.g., `/registry/pods/default/nginx`)
2. **etcd Get**: Retrieves key-value pair with revision
3. **Decryption**: Applies transformer (no-op if encryption disabled)
4. **Decoding**: Deserializes from protobuf or JSON
5. **Versioning**: Sets resource version from etcd ModRevision

### 2. CREATE Operation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:274-339`

```go
func (s *store) Create(ctx context.Context, key string, obj, out runtime.Object,
                       ttl uint64) error {
    // Clear resource version for new object
    if version, err := s.versioner.ObjectResourceVersion(obj); err == nil && version != 0 {
        return errors.New("resourceVersion should not be set on objects to be created")
    }
    s.versioner.PrepareObjectForStorage(obj)

    // Encode object
    data, err := runtime.Encode(s.codec, obj)
    if err != nil {
        return err
    }

    // Get or create TTL lease if needed
    var opts []kubernetes.OpOption
    if ttl != 0 {
        id, err := s.leaseManager.GetLease(ctx, int64(ttl))
        if err != nil {
            return err
        }
        opts = append(opts, kubernetes.WithLease(id))
    }

    // Encrypt if encryption is enabled
    newData, err := s.transformer.TransformToStorage(ctx, data,
        authenticatedDataString(preparedKey))
    if err != nil {
        return storage.NewInternalError(err.Error())
    }

    // Optimistic create (revision must be 0)
    txnResp, err := s.client.Kubernetes.OptimisticPut(ctx, preparedKey,
        newData, 0, opts...)
    if err != nil {
        return err
    }

    if out != nil {
        return s.decoder.Decode(data, out, txnResp.Header.Revision)
    }
    return nil
}
```

**Key Details**:
- **Precondition**: Object must not have resource version set
- **TTL Support**: Uses etcd leases for expiring objects
- **Optimistic Create**: Transaction fails if key already exists (revision != 0)
- **Encryption**: Transparent encryption before storage

### 3. UPDATE Operation (GuaranteedUpdate)

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:463-628`

This is the most complex operation, implementing optimistic concurrency control:

```go
func (s *store) GuaranteedUpdate(
    ctx context.Context,
    key string,
    destination runtime.Object,
    ignoreNotFound bool,
    preconditions *storage.Preconditions,
    tryUpdate storage.UpdateFunc,
    cachedExistingObject runtime.Object,
) error {
    preparedKey, err := s.prepareKey(key, false)
    if err != nil {
        return err
    }

    // Retry loop for handling conflicts
    for {
        // 1. Get current state
        origState, err := s.getCurrentState(ctx, preparedKey,
            cachedExistingObject, ignoreNotFound)
        if err != nil {
            return err
        }

        // 2. Check preconditions (UID, ResourceVersion)
        if err := preconditions.Check(preparedKey, origState.obj); err != nil {
            return err
        }

        // 3. Call user's update function
        ret, ttl, err := s.updateState(origState, tryUpdate)
        if err != nil {
            return err
        }

        // 4. Encode updated object
        data, err := runtime.Encode(s.codec, ret)
        if err != nil {
            return err
        }

        // 5. Short-circuit if data hasn't changed
        if !origState.stale && bytes.Equal(data, origState.data) {
            return s.decode(data, destination, origState.rev)
        }

        // 6. Encrypt
        newData, err := s.transformer.TransformToStorage(ctx, data,
            authenticatedDataString(preparedKey))
        if err != nil {
            return err
        }

        // 7. Optimistic update with current revision
        txnResp, err := s.client.Kubernetes.OptimisticPut(ctx, preparedKey,
            newData, origState.rev, opts...)
        if err != nil {
            return err
        }

        // 8. Check if transaction succeeded
        if txnResp.Succeeded {
            // Success! Decode and return
            return s.decode(data, destination, txnResp.Header.Revision)
        }

        // Conflict detected, retry loop continues
    }
}
```

**Retry Strategy**:
- **No Lock Required**: Uses etcd's atomic compare-and-swap
- **Automatic Retry**: Transparently handles concurrent modifications
- **Consistency**: User's `tryUpdate` function always sees consistent state
- **Short-Circuit**: Avoids write if no actual change

**Example Usage**:
```go
err := storage.GuaranteedUpdate(ctx, key, pod, false, preconditions,
    func(input runtime.Object, res storage.ResponseMeta) (runtime.Object, *uint64, error) {
        pod := input.(*api.Pod)
        // Modify pod
        pod.Spec.Containers[0].Image = "nginx:1.19"
        return pod, nil, nil
    }, nil)
```

### 4. DELETE Operation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:342-460`

```go
func (s *store) Delete(
    ctx context.Context,
    key string,
    out runtime.Object,
    preconditions *storage.Preconditions,
    validateDeletion storage.ValidateObjectFunc,
    cachedExistingObject runtime.Object,
) error {
    preparedKey, err := s.prepareKey(key, false)
    if err != nil {
        return err
    }

    // Retry loop for handling conflicts
    for {
        // 1. Get current object
        origState, err := s.getCurrentState(ctx, preparedKey,
            cachedExistingObject, false)
        if err != nil {
            return err
        }

        // 2. Check preconditions
        if err := preconditions.Check(preparedKey, origState.obj); err != nil {
            return err
        }

        // 3. Run validation function
        if err := validateDeletion(ctx, origState.obj); err != nil {
            return err
        }

        // 4. Optimistic delete with revision check
        txnResp, err := s.client.Kubernetes.OptimisticDelete(ctx, preparedKey,
            origState.rev)
        if err != nil {
            return err
        }

        // 5. Check if transaction succeeded
        if txnResp.Succeeded {
            // Return the deleted object
            if out != nil {
                return s.decode(origState.data, out, origState.rev)
            }
            return nil
        }

        // Conflict detected, retry
    }
}
```

**Features**:
- **Preconditions**: Can require specific UID or resource version
- **Validation**: Custom validation function before deletion
- **Optimistic**: Uses revision to ensure no concurrent modification
- **Returns Object**: Optionally returns the deleted object

### 5. LIST Operation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:736-899`

```go
func (s *store) GetList(ctx context.Context, key string, opts storage.ListOptions,
                        listObj runtime.Object) error {
    preparedKey, err := s.prepareKey(key, true)
    if err != nil {
        return err
    }

    // Extract list metadata and items
    listPtr, err := meta.GetItemsPtr(listObj)
    if err != nil {
        return err
    }
    v, err := conversion.EnforcePtr(listPtr)
    if err != nil {
        return err
    }

    // Determine key range
    keyPrefix := preparedKey
    if recursive {
        keyPrefix = keyPrefix + "/"
    }

    // Handle pagination
    limit := opts.Predicate.Limit
    continueToken := opts.Continue

    // List from etcd
    for {
        getResp, err := s.client.Kubernetes.List(ctx, keyPrefix,
            kubernetes.ListOptions{
                Revision:      opts.ResourceVersion,
                Limit:         limit,
                Continue:      continueToken,
            })
        if err != nil {
            return err
        }

        // Process each item
        for _, kv := range getResp.Kvs {
            // Decrypt
            data, _, err := s.transformer.TransformFromStorage(ctx, kv.Value,
                authenticatedDataString(string(kv.Key)))
            if err != nil {
                continue
            }

            // Decode
            obj, err := s.decoder.DecodeToObject(data)
            if err != nil {
                continue
            }

            // Apply predicate filter
            if opts.Predicate.Matches(obj) {
                v.Set(reflect.Append(v, reflect.ValueOf(obj).Elem()))
            }
        }

        // Handle continuation
        if getResp.More {
            continueToken = getResp.ContinueToken
            continue
        }
        break
    }

    // Set list metadata
    if err := s.versioner.UpdateList(listObj, getResp.Header.Revision,
        continueToken, nil); err != nil {
        return err
    }

    return nil
}
```

**Features**:
- **Pagination**: Supports limit and continue tokens
- **Filtering**: Applies predicate filtering (field/label selectors)
- **Consistent**: Uses single revision for entire list
- **Recursive**: Can list all objects under a prefix

### 6. WATCH Operation

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/watcher.go:105-127`

The watch implementation is split into two main components:

#### Watch Initialization

```go
func (s *store) Watch(ctx context.Context, key string,
                      opts storage.ListOptions) (watch.Interface, error) {
    preparedKey, err := s.prepareKey(key, true)
    if err != nil {
        return nil, err
    }

    return s.watcher.Watch(ctx, preparedKey,
        opts.ResourceVersion,
        opts.Predicate,
        opts.Recursive,
        opts.ProgressNotify)
}

func (w *watcher) Watch(ctx context.Context, key string, rev int64,
                        pred storage.SelectionPredicate, recursive,
                        progressNotify bool) (watch.Interface, error) {
    // Create buffered channel for watch events
    wc := &watchChan{
        watcher:           w,
        key:               key,
        initialRev:        rev,
        recursive:         recursive,
        filter:            pred,
        ctx:               ctx,
        resultChan:        make(chan watch.Event, outgoingBufSize),
        errChan:           make(chan error, 1),
    }

    // Start background goroutine to stream events
    go wc.run()

    return wc, nil
}
```

#### Watch Event Loop

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/watcher.go:571-639`

```go
func (wc *watchChan) run() {
    defer close(wc.resultChan)

    // 1. Sync initial state if watching from beginning
    if wc.initialRev == 0 {
        if err := wc.sync(); err != nil {
            wc.sendError(err)
            return
        }
    }

    // 2. Create etcd watch from revision
    opts := []clientv3.OpOption{
        clientv3.WithRev(wc.initialRev + 1),
        clientv3.WithPrevKV(),
    }
    if wc.recursive {
        opts = append(opts, clientv3.WithPrefix())
    }
    if wc.progressNotify {
        opts = append(opts, clientv3.WithProgressNotify())
    }

    etcdWatch := wc.watcher.client.Watch(wc.ctx, wc.key, opts...)

    // 3. Stream events
    for {
        select {
        case <-wc.ctx.Done():
            return
        case wresp := <-etcdWatch:
            if wresp.Err() != nil {
                wc.sendError(wresp.Err())
                return
            }

            // Process each event
            for _, e := range wresp.Events {
                event, err := wc.transform(e)
                if err != nil {
                    wc.sendError(err)
                    return
                }
                if event != nil {
                    wc.sendEvent(event)
                }
            }
        }
    }
}
```

#### Event Transformation

```go
func (wc *watchChan) transform(e *event) (*watch.Event, error) {
    // Decrypt and decode current and previous objects
    curObj, oldObj, err := wc.prepareObjs(e)
    if err != nil {
        return nil, err
    }

    // Determine event type
    switch {
    case e.isProgressNotify:
        // Bookmark event (heartbeat)
        return &watch.Event{
            Type:   watch.Bookmark,
            Object: object,
        }, nil

    case e.isDeleted:
        // Delete event
        if !wc.filter.Matches(oldObj) {
            return nil, nil  // Filter out
        }
        return &watch.Event{
            Type:   watch.Deleted,
            Object: oldObj,
        }, nil

    case e.isCreated:
        // Create event
        if !wc.filter.Matches(curObj) {
            return nil, nil  // Filter out
        }
        return &watch.Event{
            Type:   watch.Added,
            Object: curObj,
        }, nil

    default:
        // Modification - smart filtering
        curMatch := wc.filter.Matches(curObj)
        oldMatch := wc.filter.Matches(oldObj)

        switch {
        case curMatch && oldMatch:
            // Still matches, send Modified
            return &watch.Event{
                Type:   watch.Modified,
                Object: curObj,
            }, nil
        case !curMatch && oldMatch:
            // Stopped matching, send Deleted
            return &watch.Event{
                Type:   watch.Deleted,
                Object: oldObj,
            }, nil
        case curMatch && !oldMatch:
            // Started matching, send Added
            return &watch.Event{
                Type:   watch.Added,
                Object: curObj,
            }, nil
        default:
            // Never matched, filter out
            return nil, nil
        }
    }
}
```

**Smart Filtering**:
- Objects can "appear" (Added) when they start matching the filter
- Objects can "disappear" (Deleted) when they stop matching
- Example: Watch `status.phase=Running` - pod appears when it starts running

---

## Security and Encryption

### Encryption at Rest

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/value/encrypt/`

The `value.Transformer` interface provides transparent encryption:

```go
type Transformer interface {
    // TransformFromStorage decrypts data from etcd
    TransformFromStorage(ctx context.Context, data []byte,
                        dataCtx Context) ([]byte, bool, error)

    // TransformToStorage encrypts data before etcd
    TransformToStorage(ctx context.Context, data []byte,
                      dataCtx Context) ([]byte, error)
}
```

**Encryption Flow**:
1. **Write Path**: Object → Encode → Encrypt → etcd
2. **Read Path**: etcd → Decrypt → Decode → Object

**Providers**:
- **Identity**: No encryption (default)
- **AES-CBC**: AES encryption with PKCS7 padding
- **AES-GCM**: AES-GCM authenticated encryption
- **KMS**: External key management service

**Configuration**:
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-secret>
      - identity: {}
```

### Key Rotation

Encryption supports multiple keys:
- **Current Key**: Used for encryption (first in list)
- **Previous Keys**: Can decrypt but not encrypt
- **Rotation Process**:
  1. Add new key to configuration
  2. Restart API servers
  3. Re-encrypt all data: `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`
  4. Remove old key from configuration

---

## Resource Versioning

### How Resource Versions Work

Kubernetes uses etcd's ModRevision as the resource version:

```go
type Versioner interface {
    // UpdateObject sets the resource version on an object
    UpdateObject(obj runtime.Object, resourceVersion uint64) error

    // PrepareObjectForStorage clears the resource version
    PrepareObjectForStorage(obj runtime.Object) error

    // ObjectResourceVersion extracts the resource version
    ObjectResourceVersion(obj runtime.Object) (uint64, error)

    // ParseResourceVersion parses a string resource version
    ParseResourceVersion(resourceVersion string) (uint64, error)
}
```

### Usage in Operations

**GET**: Returns object with its resource version
```go
pod := &v1.Pod{}
storage.Get(ctx, key, storage.GetOptions{}, pod)
// pod.ResourceVersion = "12345"
```

**UPDATE**: Requires matching resource version to prevent conflicts
```go
preconditions := &storage.Preconditions{
    ResourceVersion: pointer.String("12345"),
}
storage.GuaranteedUpdate(ctx, key, pod, false, preconditions, updateFunc, nil)
```

**WATCH**: Start watching from specific resource version
```go
watcher, err := storage.Watch(ctx, key, storage.ListOptions{
    ResourceVersion: "12345",
})
```

**LIST**: Returns list with resource version for consistent pagination
```go
list := &v1.PodList{}
storage.GetList(ctx, key, storage.ListOptions{
    Limit: 100,
}, list)
// list.ResourceVersion = "12500"
// list.Continue = "eyJydiI6IjEyNTAwIiwic3RhcnQiOiJwb2RzL2RlZmF1bHQvbmdpbnhceDAwIn0"
```

### Resource Version Semantics

| Value | Meaning | Use Case |
|-------|---------|----------|
| ` ` (empty) | Most recent | Normal GET/LIST |
| `"0"` | Any version (may not be most recent) | Best effort LIST |
| Specific number | Exact historical version | Consistent read, watch continuation |

---

## Performance Optimizations

### 1. Watch Cache

The cacher dramatically improves performance:

**Without Cacher**:
- Every LIST hits etcd directly
- etcd must serialize, transmit large responses
- Network and CPU intensive

**With Cacher**:
- LIST served from memory (microseconds vs milliseconds)
- Reflector maintains single watch to etcd
- Hundreds of clients can watch without multiplying etcd load

**Memory Cost**:
- Stores complete copy of all objects of a type
- For 10,000 pods × 10 KB each = 100 MB
- Acceptable trade-off for read performance

### 2. Pagination

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go:768-883`

Pagination prevents large LIST operations from overwhelming etcd and API server:

```go
opts := storage.ListOptions{
    Predicate: storage.SelectionPredicate{
        Limit: 500,
    },
}
storage.GetList(ctx, key, opts, list)
// list.Continue will be set if more results exist
```

**Benefits**:
- Bounded memory usage
- Faster time-to-first-result
- Better user experience for large result sets

### 3. Compaction

**Location**: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go`

etcd maintains history of all changes. Compaction removes old revisions:

```go
type Compactor interface {
    // Start begins periodic compaction
    Start(ctx context.Context)
}
```

**Strategy**:
- Periodic compaction (default: every 5 minutes)
- Keeps recent history (default: 5 minute window)
- Allows watch from recent revisions
- Prevents unbounded etcd growth

**Configuration**:
```bash
kube-apiserver \
  --etcd-compaction-interval=5m \
  --default-watch-cache-size=100
```

### 4. Efficient Watch Restart

**Bookmark Support**: etcd periodically sends "progress notify" events with current revision, allowing clients to checkpoint and resume efficiently.

```go
opts := storage.ListOptions{
    ResourceVersion: "12345",
    ProgressNotify:  true,
}
watcher, _ := storage.Watch(ctx, key, opts)
for event := range watcher.ResultChan() {
    if event.Type == watch.Bookmark {
        // Save event.Object.ResourceVersion for recovery
        saveCheckpoint(event.Object.ResourceVersion)
    }
}
```

---

## Error Handling and Retries

### Retry Strategy

The etcd shim implements intelligent retry logic:

**GuaranteedUpdate Retry Loop**:
- **Conflict**: Automatic retry (another client modified the object)
- **Network Error**: Propagate to caller (may retry at higher level)
- **Precondition Failed**: Propagate immediately (user error)

**Watch Retry**:
- **Connection Lost**: Automatically reconnect and resume from last revision
- **Compaction**: If requested revision is too old, may need to re-list

### Error Types

```go
// Object already exists
storage.NewKeyExistsError(key, revision)

// Object not found
storage.NewKeyNotFoundError(key, revision)

// Revision too old (compacted)
storage.NewTooLargeResourceVersionError(revision, frontier)

// Internal error (encoding, encryption, etc.)
storage.NewInternalError(msg)
```

---

## etcd Key Structure

### Key Prefixing

All Kubernetes objects are stored under a consistent key structure:

```
/registry/<resource>/<namespace>/<name>
/registry/<resource>/<name>                  (cluster-scoped)
```

**Examples**:
```
/registry/pods/default/nginx
/registry/pods/kube-system/coredns-xyz
/registry/services/default/kubernetes
/registry/namespaces/default
/registry/nodes/worker-1
```

### Key Prefix Configuration

**Location**: `pkg/kubeapiserver/default_storage_factory_builder.go:66-162`

```go
DefaultResourcePrefixes: map[schema.GroupResource]string{
    {Group: "", Resource: "pods"}:              "pods",
    {Group: "", Resource: "services"}:          "services",
    {Group: "", Resource: "namespaces"}:        "namespaces",
    {Group: "apps", Resource: "deployments"}:   "deployments",
    // ...
}
```

### Multi-tenancy via Prefixes

Different resource types can use:
- Different etcd clusters (via overrides)
- Different encryption keys
- Different storage classes (HDD vs SSD)

---

## Code Reference Summary

### Core Abstractions

| Component | File | Key Lines |
|-----------|------|-----------|
| Storage Interface | `staging/src/k8s.io/apiserver/pkg/storage/interfaces.go` | 169-279 |
| Versioner Interface | `staging/src/k8s.io/apiserver/pkg/storage/interfaces.go` | 46-71 |
| Value Transformer | `staging/src/k8s.io/apiserver/pkg/storage/value/transformer.go` | - |

### etcd3 Implementation

| Component | File | Key Lines |
|-----------|------|-----------|
| Store Struct | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 80-100 |
| Get Operation | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 238-271 |
| Create Operation | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 274-339 |
| Delete Operation | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 342-460 |
| GuaranteedUpdate | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 463-628 |
| List Operation | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` | 736-899 |
| Watch Initialization | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/watcher.go` | 105-127 |
| Watch Event Loop | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/watcher.go` | 180-382 |
| Event Transformation | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/watcher.go` | 571-639 |
| Compactor | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go` | - |

### Caching Layer

| Component | File | Key Lines |
|-----------|------|-----------|
| Cacher Struct | `staging/src/k8s.io/apiserver/pkg/storage/cacher/cacher.go` | 261-342 |
| Cacher Get | `staging/src/k8s.io/apiserver/pkg/storage/cacher/cacher.go` | 678-711 |
| Cacher Watch | `staging/src/k8s.io/apiserver/pkg/storage/cacher/cacher.go` | 1088-1180 |
| Watch Cache | `staging/src/k8s.io/apiserver/pkg/storage/cacher/watch_cache.go` | - |

### Factory and Construction

| Component | File | Key Lines |
|-----------|------|-----------|
| Storage Factory | `staging/src/k8s.io/apiserver/pkg/server/storage/storage_factory.go` | 65-373 |
| Backend Factory | `staging/src/k8s.io/apiserver/pkg/storage/storagebackend/factory/factory.go` | 33-42 |
| etcd3 Factory | `staging/src/k8s.io/apiserver/pkg/storage/storagebackend/factory/etcd3.go` | 426-484 |
| Default Factory Builder | `pkg/kubeapiserver/default_storage_factory_builder.go` | 66-162 |

---

## Summary

The etcd shim is a sophisticated multi-layered architecture that:

1. **Abstracts Storage**: Provides a generic `storage.Interface` that hides etcd details
2. **Optimizes Performance**: Uses in-memory caching to dramatically reduce etcd load
3. **Ensures Security**: Supports transparent encryption at rest
4. **Guarantees Consistency**: Implements optimistic concurrency control
5. **Enables Reactivity**: Provides efficient watch mechanisms
6. **Handles Scale**: Supports pagination, compaction, and efficient resource versioning

The layered design allows Kubernetes to:
- Maintain clean separation of concerns
- Optimize read-heavy workloads via caching
- Support encryption without changing business logic
- Potentially swap storage backends in the future
- Provide a consistent API across all resource types

Understanding this architecture is crucial for:
- **Performance Tuning**: Configuring cache sizes, compaction intervals
- **Troubleshooting**: Understanding where bottlenecks may occur
- **Feature Development**: Adding new resource types or storage features
- **Operations**: Configuring encryption, monitoring etcd health
