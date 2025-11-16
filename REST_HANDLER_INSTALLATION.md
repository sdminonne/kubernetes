# REST Handler Installation in kube-apiserver

This document explains how REST handlers are installed and registered in the kube-apiserver binary.

## Overview

The kube-apiserver uses a layered architecture to install REST handlers for Kubernetes APIs. The process involves creating storage providers for each API group, which generate REST storage implementations that are then registered as HTTP routes using the go-restful library.

## Architecture Flow

```
main()
  → CreateServerChain()
    → config.KubeAPIs.New()
      → StorageProviders()  // Creates provider for each API group
      → InstallAPIs()
        → For each provider:
          → provider.NewRESTStorage()  // Returns map[string]rest.Storage
          → InstallLegacyAPIGroup() or InstallAPIGroups()
            → installAPIResources()
              → apiGroupVersion.InstallREST()
                → APIInstaller.Install()
                  → registerResourceHandlers()  // Registers HTTP routes
                    → ws.GET/POST/PUT/PATCH/DELETE().To(handler)
```

## Step-by-Step Breakdown

### 1. Entry Point and Server Creation

**Location**: `cmd/kube-apiserver/app/server.go:176-197`

`CreateServerChain()` creates three chained API servers:
- **apiExtensionsServer** - Handles CustomResourceDefinitions (CRDs)
- **kubeAPIServer** - Handles core Kubernetes APIs (main focus)
- **aggregatorServer** - Handles aggregated APIs

Each server delegates to the next in the chain for resources it doesn't handle.

```go
func CreateServerChain(config CompletedConfig) (*aggregatorapiserver.APIAggregator, error) {
    apiExtensionsServer, err := config.ApiExtensions.New(...)
    kubeAPIServer, err := config.KubeAPIs.New(apiExtensionsServer.GenericAPIServer)
    aggregatorServer, err := controlplaneapiserver.CreateAggregatorServer(...)
    return aggregatorServer, nil
}
```

### 2. API Installation Entry Point

**Location**: `pkg/controlplane/instance.go:317-343`

The `CompletedConfig.New()` method:
1. Creates the control plane server
2. Gets storage providers via `StorageProviders()` (line 336)
3. Installs them via `InstallAPIs()` (line 341)

```go
func (c CompletedConfig) New(delegationTarget genericapiserver.DelegationTarget) (*Instance, error) {
    cp, err := c.ControlPlane.New(controlplaneapiserver.KubeAPIServer, delegationTarget)

    restStorageProviders, err := c.StorageProviders(client)

    if err := s.ControlPlane.InstallAPIs(restStorageProviders...); err != nil {
        return nil, err
    }
    // ...
}
```

### 3. Storage Provider Registration

**Location**: `pkg/controlplane/instance.go:387-443`

The `StorageProviders()` function creates a list of `RESTStorageProvider` implementations, one per API group. The order matters for discovery priority.

```go
func (c CompletedConfig) StorageProviders(client *kubernetes.Clientset) ([]controlplaneapiserver.RESTStorageProvider, error) {
    providers := []controlplaneapiserver.RESTStorageProvider{
        legacyRESTStorageProvider,      // core/v1 (pods, services, etc.)
        apiserverinternalrest.StorageProvider{},
        authenticationrest.RESTStorageProvider{...},
        authorizationrest.RESTStorageProvider{...},
        autoscalingrest.RESTStorageProvider{},
        batchrest.RESTStorageProvider{},
        certificatesrest.RESTStorageProvider{...},
        coordinationrest.RESTStorageProvider{},
        discoveryrest.StorageProvider{},
        networkingrest.RESTStorageProvider{},
        noderest.RESTStorageProvider{},
        policyrest.RESTStorageProvider{},
        rbacrest.RESTStorageProvider{...},
        schedulingrest.RESTStorageProvider{},
        storagerest.RESTStorageProvider{},
        svmrest.RESTStorageProvider{},
        flowcontrolrest.RESTStorageProvider{...},
        appsrest.StorageProvider{},
        admissionregistrationrest.RESTStorageProvider{...},
        eventsrest.RESTStorageProvider{...},
        resourcerest.RESTStorageProvider{...},
    }
    return providers, nil
}
```

Each provider is defined in `pkg/registry/<group>/rest/storage_<group>.go`

### 4. Example: Apps API Group

**Location**: `pkg/registry/apps/rest/storage_apps.go:38-108`

Each storage provider must implement the `RESTStorageProvider` interface:

```go
type RESTStorageProvider interface {
    GroupName() string
    NewRESTStorage(apiResourceConfigSource, restOptionsGetter) (genericapiserver.APIGroupInfo, error)
}
```

For the apps group:

```go
func (p StorageProvider) NewRESTStorage(...) (genericapiserver.APIGroupInfo, error) {
    storage := map[string]rest.Storage{}

    // deployments
    deploymentStorage, err := deploymentstore.NewStorage(restOptionsGetter)
    storage["deployments"] = deploymentStorage.Deployment
    storage["deployments/status"] = deploymentStorage.Status
    storage["deployments/scale"] = deploymentStorage.Scale

    // statefulsets
    statefulSetStorage, err := statefulsetstore.NewStorage(restOptionsGetter)
    storage["statefulsets"] = statefulSetStorage.StatefulSet
    storage["statefulsets/status"] = statefulSetStorage.Status
    storage["statefulsets/scale"] = statefulSetStorage.Scale

    // daemonsets, replicasets, controllerrevisions...

    return apiGroupInfo, nil
}
```

### 5. Resource Storage Implementation

**Location**: `pkg/registry/apps/deployment/storage/storage.go:88-116`

Individual resource storage embeds `genericregistry.Store` which provides the actual CRUD operations:

```go
type REST struct {
    *genericregistry.Store
}

func NewREST(optsGetter generic.RESTOptionsGetter) (*REST, *StatusREST, *RollbackREST, error) {
    store := &genericregistry.Store{
        NewFunc:                   func() runtime.Object { return &apps.Deployment{} },
        NewListFunc:               func() runtime.Object { return &apps.DeploymentList{} },
        DefaultQualifiedResource:  apps.Resource("deployments"),

        CreateStrategy:      deployment.Strategy,
        UpdateStrategy:      deployment.Strategy,
        DeleteStrategy:      deployment.Strategy,
        ResetFieldsStrategy: deployment.Strategy,

        TableConvertor: printerstorage.TableConvertor{...},
    }

    options := &generic.StoreOptions{RESTOptions: optsGetter}
    if err := store.CompleteWithOptions(options); err != nil {
        return nil, nil, nil, err
    }

    return &REST{store}, &StatusREST{...}, &RollbackREST{...}, nil
}
```

The Store is configured with:
- **NewFunc** - Creates empty resource object
- **CreateStrategy/UpdateStrategy/DeleteStrategy** - Validation, defaulting, and business logic
- **RESTOptions** - Storage backend configuration (etcd path, encoding, etc.)

### 6. Generic API Server Installation

**Location**: `pkg/controlplane/apiserver/apis.go:88-153`

`InstallAPIs()` processes all storage providers:

```go
func (s *Server) InstallAPIs(restStorageProviders ...RESTStorageProvider) error {
    for _, restStorageBuilder := range restStorageProviders {
        groupName := restStorageBuilder.GroupName()
        apiGroupInfo, err := restStorageBuilder.NewRESTStorage(s.APIResourceConfigSource, s.RESTOptionsGetter)

        if len(groupName) == 0 {
            // Legacy core API group - install to /api
            s.GenericAPIServer.InstallLegacyAPIGroup(genericapiserver.DefaultLegacyAPIPrefix, &apiGroupInfo)
        } else {
            // Named API groups - install to /apis/<group>
            nonLegacy = append(nonLegacy, &apiGroupInfo)
        }
    }

    s.GenericAPIServer.InstallAPIGroups(nonLegacy...)
    return nil
}
```

This separates:
- **Core APIs** (empty group name) → `/api/v1/...`
- **Named API groups** → `/apis/<group>/<version>/...`

### 7. Installing API Resources

**Location**: `staging/src/k8s.io/apiserver/pkg/server/genericapiserver.go:783-843`

`installAPIResources()` processes each version of an API group:

```go
func (s *GenericAPIServer) installAPIResources(apiPrefix string, apiGroupInfo *APIGroupInfo, typeConverter managedfields.TypeConverter) error {
    for _, groupVersion := range apiGroupInfo.PrioritizedVersions {
        apiGroupVersion, err := s.getAPIGroupVersion(apiGroupInfo, groupVersion, apiPrefix)

        apiGroupVersion.TypeConverter = typeConverter
        apiGroupVersion.MaxRequestBodyBytes = s.maxRequestBodyBytes

        discoveryAPIResources, resourceInfos, err := apiGroupVersion.InstallREST(s.Handler.GoRestfulContainer)

        // Register with aggregated discovery
        s.AggregatedDiscoveryGroupManager.AddGroupVersion(...)
    }
    return nil
}
```

### 8. Creating WebService

**Location**: `staging/src/k8s.io/apiserver/pkg/endpoints/groupversion.go:106-123`

`InstallREST()` creates and installs a go-restful WebService:

```go
func (g *APIGroupVersion) InstallREST(container *restful.Container) ([]apidiscoveryv2.APIResourceDiscovery, []*storageversion.ResourceInfo, error) {
    prefix := path.Join(g.Root, g.GroupVersion.Group, g.GroupVersion.Version)
    installer := &APIInstaller{
        group:             g,
        prefix:            prefix,
        minRequestTimeout: g.MinRequestTimeout,
    }

    apiResources, resourceInfos, ws, registrationErrors := installer.Install()
    versionDiscoveryHandler := discovery.NewAPIVersionHandler(g.Serializer, g.GroupVersion, staticLister{apiResources})
    versionDiscoveryHandler.AddToWebService(ws)
    container.Add(ws)

    return aggregatedDiscoveryResources, resourceInfos, utilerrors.NewAggregate(registrationErrors)
}
```

### 9. Registering HTTP Routes

**Location**: `staging/src/k8s.io/apiserver/pkg/endpoints/installer.go:195-989`

#### Install Method

```go
func (a *APIInstaller) Install() ([]metav1.APIResource, []*storageversion.ResourceInfo, *restful.WebService, []error) {
    ws := a.newWebService()

    // Register paths in sorted order for deterministic swagger spec
    paths := make([]string, len(a.group.Storage))
    for path := range a.group.Storage {
        paths = append(paths, path)
    }
    sort.Strings(paths)

    for _, path := range paths {
        apiResource, resourceInfo, err := a.registerResourceHandlers(path, a.group.Storage[path], ws)
        // Collect results...
    }
    return apiResources, resourceInfos, ws, errors
}
```

#### Register Resource Handlers

The `registerResourceHandlers()` method (lines 287-989):

1. **Determines capabilities** by type-asserting the storage object:
   ```go
   creater, isCreater := storage.(rest.Creater)
   lister, isLister := storage.(rest.Lister)
   getter, isGetter := storage.(rest.Getter)
   updater, isUpdater := storage.(rest.Updater)
   patcher, isPatcher := storage.(rest.Patcher)
   watcher, isWatcher := storage.(rest.Watcher)
   gracefulDeleter, isGracefulDeleter := storage.(rest.GracefulDeleter)
   collectionDeleter, isCollectionDeleter := storage.(rest.CollectionDeleter)
   ```

2. **Registers HTTP routes** based on capabilities:

   ```go
   switch action.Verb {
   case request.MethodGet:
       handler := restfulGetResource(getter, reqScope)
       route := ws.GET(action.Path).To(handler).
           Doc("read the specified " + kind).
           Returns(http.StatusOK, "OK", producedObject)
       routes = append(routes, route)

   case request.MethodList:
       handler := restfulListResource(lister, watcher, reqScope, false, a.minRequestTimeout)
       route := ws.GET(action.Path).To(handler).
           Doc("list objects of kind " + kind).
           Returns(http.StatusOK, "OK", versionedList)
       routes = append(routes, route)

   case request.MethodPost:
       handler := restfulCreateResource(creater, reqScope, admit)
       route := ws.POST(action.Path).To(handler).
           Doc("create" + article + kind).
           Returns(http.StatusCreated, "Created", producedObject)
       routes = append(routes, route)

   case request.MethodPut:
       handler := restfulUpdateResource(updater, reqScope, admit)
       route := ws.PUT(action.Path).To(handler).
           Doc("replace the specified " + kind).
           Returns(http.StatusOK, "OK", producedObject)
       routes = append(routes, route)

   case request.MethodPatch:
       handler := restfulPatchResource(patcher, reqScope, admit, supportedTypes)
       route := ws.PATCH(action.Path).To(handler).
           Doc("partially update the specified " + kind).
           Returns(http.StatusOK, "OK", producedObject)
       routes = append(routes, route)

   case request.MethodDelete:
       handler := restfulDeleteResource(gracefulDeleter, isGracefulDeleter, reqScope, admit)
       route := ws.DELETE(action.Path).To(handler).
           Doc("delete" + article + kind).
           Returns(http.StatusOK, "OK", deleteReturnType)
       routes = append(routes, route)
   }
   ```

## Example: Deployment Resource Routes

For a deployment resource in the apps/v1 API group, the following routes are registered:

```
GET    /apis/apps/v1/namespaces/{namespace}/deployments           → List deployments
POST   /apis/apps/v1/namespaces/{namespace}/deployments           → Create deployment
GET    /apis/apps/v1/namespaces/{namespace}/deployments/{name}    → Get deployment
PUT    /apis/apps/v1/namespaces/{namespace}/deployments/{name}    → Update deployment
PATCH  /apis/apps/v1/namespaces/{namespace}/deployments/{name}    → Patch deployment
DELETE /apis/apps/v1/namespaces/{namespace}/deployments/{name}    → Delete deployment

GET    /apis/apps/v1/namespaces/{namespace}/deployments/{name}/status    → Get status
PUT    /apis/apps/v1/namespaces/{namespace}/deployments/{name}/status    → Update status
PATCH  /apis/apps/v1/namespaces/{namespace}/deployments/{name}/status    → Patch status

GET    /apis/apps/v1/namespaces/{namespace}/deployments/{name}/scale     → Get scale
PUT    /apis/apps/v1/namespaces/{namespace}/deployments/{name}/scale     → Update scale
PATCH  /apis/apps/v1/namespaces/{namespace}/deployments/{name}/scale     → Patch scale
```

## Key Components Summary

| Component | Location | Purpose |
|-----------|----------|---------|
| RESTStorageProvider | `pkg/registry/<group>/rest/` | Creates storage map for API group |
| Storage Implementation | `pkg/registry/<group>/<resource>/storage/` | Implements CRUD for specific resource |
| genericregistry.Store | `staging/src/k8s.io/apiserver/pkg/registry/generic/registry/` | Generic storage backend (etcd) |
| APIInstaller | `staging/src/k8s.io/apiserver/pkg/endpoints/installer.go` | Registers HTTP routes |
| go-restful | Third-party library | HTTP routing framework |

## Request Flow

When a client makes an API request:

```
HTTP Request (e.g., GET /apis/apps/v1/namespaces/default/deployments/nginx)
  ↓
go-restful Router
  ↓
Route Handler (e.g., restfulGetResource)
  ↓
rest.Getter.Get() (from storage implementation)
  ↓
genericregistry.Store.Get()
  ↓
Storage Backend (etcd)
  ↓
Response encoding and serialization
  ↓
HTTP Response (JSON/YAML/Protobuf)
```

## Adding a New Resource

To add a new resource to kube-apiserver:

1. **Define API types** in `pkg/apis/<group>/types.go` (internal) and `staging/src/k8s.io/api/<group>/<version>/types.go` (versioned)
2. **Create storage implementation** in `pkg/registry/<group>/<resource>/storage/`
3. **Add to REST storage provider** in `pkg/registry/<group>/rest/storage_<group>.go`
4. **Run code generation** with `hack/update-codegen.sh`
5. **Implement validation** in `pkg/apis/<group>/validation/`
6. **Implement strategy** in `pkg/registry/<group>/<resource>/strategy.go`

The generic API server machinery handles the rest automatically.
