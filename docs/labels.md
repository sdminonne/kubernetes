# Labels

_Labels_ are key/value pairs that are attached to objects, such as pods.
Labels can be used to organize and to select subsets of objects.  Labels can be attached to objects at creation time but they can be modified at any time.
Each object can have a set of key/value labels set on it, with at most one label with a particular key.
```
"labels": {
  "key1" : "value1",
  "key2" : "value2"
}
```

Unlike [names and UIDs](identifiers.md), labels do not provide uniqueness. In general, we expect many objects to carry the same label(s).
Sets identified by labels could be overlapping (think Venn diagrams). For instance, a service might target all pods with `"tier": "frontend"` and  `"environment" : "prod"`.  Now say you have 10 replicated pods that make up this tier.  But you want to be able to 'canary' a new version of this component.  You could set up a `replicationController` (with `replicas` set to 9) for the bulk of the replicas with labels `"tier" : "frontend"` and `"environment" : "prod"` and `"track" : "stable"` and another `replicationController` (with `replicas` set to 1) for the canary with labels `"tier" : "frontend"` and  `"environmen" : "prod"` and `"track" : canary`.  Now the service is covering both the canary and non-canary pods.  But you can mess with the `replicationControllers` separately to test things out, monitor the results, etc.

Valid label keys are comprised of two segments - prefix and name - separated by a slash (`/`).  The name segment is required and must be a DNS label: 63 characters or less, all lowercase, beginning and ending with an alphanumeric character (`[a-z0-9]`), with dashes (`-`) and alphanumerics between.  The prefix and slash are optional.  If specified, the prefix must be a DNS
subdomain (a series of DNS labels separated by dots (`.`), not longer than 253 characters in total.

If the prefix is omitted, the label key is presumed to be private to the user. System components which use labels must specify a prefix.  The `kubernetes.io` prefix is reserved for kubernetes core components.

Valid label values must be shorter than 64 characters, accepted characters are (`[-A-Za-z0-9_.]`) but the first character must be  (`[A-Za-z0-9]`).


Labels let you categorize objects in a complex service deployment or batch processing pipelines along multiple
dimensions, such as:
   - `"release" : "stable"`, `"release" : "canary"`, ...
   - `"environment" : "dev"`, `"environment" : "qa"`, `"environment" : "production"`
   - `"tier" : "frontend"`, `"tier" : "backend"`, `"tier" : "middleware"`
   - `"partition" : "customerA"`, `"partition" : "customerB"`, ...
   - `"track" : "daily"`, `"track" : "weekly"`

These are just examples; you are free to develop your own conventions.

## Label selectors

Via a label selector, the client/user can identify a set of objects. The label selector is the core grouping primitive in Kubernetes.
The API currently supports two types of selectors equality based and set based.
A label selector can be made of multiple _requirements_ which are comma separated. In case of multiple requirements, all must be satisfied so comma separaator acts as an AND logical operator.


### Equality based requirement

Equality (or inequality) based requirements permit to filter by label keys and values. Matching objects must have all of the specified labels (both keys and values), though they may have additional labels as well.
Three kinds of operators are admitted `=`,`==`,`!=`. The first two represent _equality_ and they are simply synonyms. While the latter represent _inequality_. For example:
```
environment = production
tier != frontend
```

The first example permits to filter all the resources with key equals to `environment` and value equals to `production`.
The second examples permits to filter all the resources with key equals to `tier` and value different than `frontend`.
One could filter for resource in `production` but not `frontend` using comma: `environment=production,tier!=frontend`

### Set based requirement

Set based label requirements permit to filter by label keys and a set of values. Matching object must have all of the specified labels (both keys and at least one of the specified values). Three kind of operartor are admitted `in`,`notin` and exists (only the key identifier). For example:
```
environment in (production, qa)
tier notin (frontend, backend)
partition
```
The first example permits to filter all the resources with key equals to `environment` and value equals to `production` or `qa`.
The second example permits to filter all the resources with key equals to `tier` and value different than `frontend` and `backend`.
The third example permits to filter all the resources with key equals to `partition`, no values are checked.
Similary the comma separator acts as an _AND_ operator for example filtering resource with a `partition` key (not matter the value) and with `environment` different than  `qa`. For example: `partition,environment notin (qa)`.
The set based label selector is more general than equality based form since `environment=production` is equivalent to `environment in (production)` similarly for `!=` and `notin`.

Set based requirements can be mixed with equality based requirements. For example: `partition,environment!=qa`.


LIST and WATCH operations may specify label selectors to filter the sets of objects returned using a query parameter: `?labels=key1%3Dvalue1,key2%3Dvalue2,...`.

## Future developments

See the [Labels Design Document](./design/labels.md) for more about how we expect labels and selectors to be used, and planned features.
