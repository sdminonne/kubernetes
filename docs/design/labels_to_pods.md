# Kubernetes Proposal - Metadata to containers

## Rationale

A proposal to supply an easy-to-use mechanism to propagate client attributes stored in metadata to applications. Discussions already started on github: [#560](https://github.com/GoogleCloudPlatform/kubernetes/issues/560), [#1768](https://github.com/GoogleCloudPlatform/kubernetes/issues/1768). 

## Background

Today Kubernetes [labels](/docs/labels.md) allow user to decorate resources. Since a resource can bring different labels, it may belong to multiple sub-set of the cluster. More specifically labelling a pod, user can add some functional information the application running in it. For example an application may need to be aware of the labels assigned to the pod or the replication controller driving the pods (like prefix logging entries to aggregate information for monitoring purpouse).

## Proposed Design

This design proposes to modify json/yaml file to add a new block. The new block will be added to the container block.

```
"generated": [
    { "env":
        [ { "from": "labels",
            "entries":
                [ { "generate": "K8_LABEL_%s",
                    "name": "name" }
                ]
          },
          { "from": "annotations",
            "entries":
                [ { "generate": "%s",
                    "name": "version" }
                ]
          } ]
      },
    {"volume":
       [ { "path": "etc",
           "from": "labels",
           "filename": "labels",
           "entries":
               [ { "generate": "%s",
                   "name": "name" }
               ]
         }    
      ]
    }
]
```

Some explanation about the new block:
The are two kind of statement `env` and `volume`.
* `env` permits to generate environment variables to be injected at the bootstrap of the container.
* `volume` permits to create a file to be mounted at the `path` values with the name specified with `filename` value.
the `from` value for the moment could be only `labels` but in theory it could bet set to any `[metadata](/docs/api-conventions.md#metadata)`. So in theory it couldbe for example  `annotations`, `creationTimestamp`, `labels`, `namespace`, `name`, `resourceVersion`, `uid`.


## Limitations

Limitations are obviously that both `env` and `volume` can be generated at container. While, for example, labels can be modified on the fly (see `kubectl label` command) the labels in env vars couldn't be modified at runtime. This is slightly different for `/etc/labels` file even if at the moment this is not supported see [#560](https://github.com/GoogleCloudPlatform/kubernetes/issues/560)
