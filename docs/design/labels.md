# Labels

_Labels_ are key/value pairs identifying client/user-defined attributes (and non-primitive system-generated attributes) of API objects, which are stored and returned as part of the [metadata of those objects](/docs/api-conventions.md). Labels can be used to organize and to select subsets of objects according to these attributes.

Each object can have a set of key/value labels set on it, with at most one label with a particular key.
```
"labels": {
  "key1" : "value1",
  "key2" : "value2"
}
```

We also [plan](https://github.com/GoogleCloudPlatform/kubernetes/issues/560) to make labels available inside pods and [lifecycle hooks](/docs/container-environment.md).

## Motivation

Service deployments and batch processing pipelines are often multi-dimensional entities (e.g., multiple partitions or deployments, multiple release tracks, multiple tiers, multiple micro-services per tier). Management often requires cross-cutting operations, which breaks encapsulation of strictly hierarchical representations, especially rigid hierarchies determined by the infrastructure rather than by users. Labels enable users to map their own organizational structures onto system objects in a loosely coupled fashion, without requiring clients to store these mappings.

## Label selectors

Label selectors permit very simple filtering by label keys and values. The simplicity of label selectors is deliberate. It is intended to facilitate transparency for humans, easy set overlap detection, efficient indexing, and reverse-indexing (i.e., finding all label selectors matching an object's labels - https://github.com/GoogleCloudPlatform/kubernetes/issues/1348).

LIST and WATCH operations may specify label selectors to filter the sets of objects returned using a query parameter: `?labels=key1%3Dvalue1,key2%3Dvalue2,...`. We may extend such filtering to DELETE operations in the future.

Kubernetes also currently supports two objects that use label selectors to keep track of their members, `service`s and `replicationController`s:
- `service`: A [service](/docs/services.md) is a configuration unit for the proxies that run on every worker node.  It is named and points to one or more pods.
- `replicationController`: A [replication controller](/docs/replication-controller.md) ensures that a specified number of pod "replicas" are running at any one time.  If there are too many, it'll kill some.  If there are too few, it'll start more.

For management convenience and consistency, `services` and `replicationControllers` may themselves have labels and would generally carry the labels their corresponding pods have in common.

In the future, label selectors will be used to identify other types of distributed service workers, such as worker pool members or peers in a distributed application.

Individual labels are used to specify identifying metadata, and to convey the semantic purposes/roles of pods of containers. Examples of typical pod label keys include `service`, `environment` (e.g., with values `dev`, `qa`, or `production`), `tier` (e.g., with values `frontend` or `backend`), and `track` (e.g., with values `daily` or `weekly`), but you are free to develop your own conventions.

Pods (and other objects) may belong to multiple sets simultaneously, which enables representation of service substructure and/or superstructure. In particular, labels are intended to facilitate the creation of non-hierarchical, multi-dimensional deployment structures. They are useful for a variety of management purposes (e.g., configuration, deployment) and for application introspection and analysis (e.g., logging, monitoring, alerting, analytics). Without the ability to form sets by intersecting labels, many implicitly related, overlapping flat sets would need to be created, for each subset and/or superset desired, which would lose semantic information and be difficult to keep consistent. Purely hierarchically nested sets wouldn't readily support slicing sets across different dimensions.

Pods may be removed from these sets by changing their labels. This flexibility may be used to remove pods from service for debugging, data recovery, etc. Kubernetes will automatically restart the pod just relabeled.

## Labels vs. annotations

We'll eventually index and reverse-index labels for efficient queries and watches, use them to sort and group in UIs and CLIs, etc. We don't want to pollute labels with non-identifying, especially large and/or structured, data. Non-identifying information should be recorded using [annotations](/docs/annotations.md).
