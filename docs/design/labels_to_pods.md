# Kubernetes Proposal - Labels to containers

## Rationale

A proposal to supply an easy-to-use mechanism to propagate client attributes stored in labels to applications. Discussions already started on github: [#560](https://github.com/GoogleCloudPlatform/kubernetes/issues/560), [#1768](https://github.com/GoogleCloudPlatform/kubernetes/issues/1768).

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
       [ { "path": "etc,
           "from": "labels",
           "entries":
               [ { "generate": "%s",
                   "name": "name" }
               ]
         },
         { "from": "annotations",
           "entries":
                [ { "generate": "K8_ANNOTATION_%s",
                    "name": "version" }
                ]
          }
      ]
    }
]
```


## Limitations
