<!-- BEGIN MUNGE: UNVERSIONED_WARNING -->

<!-- BEGIN STRIP_FOR_RELEASE -->

<img src="http://kubernetes.io/img/warning.png" alt="WARNING"
     width="25" height="25">
<img src="http://kubernetes.io/img/warning.png" alt="WARNING"
     width="25" height="25">
<img src="http://kubernetes.io/img/warning.png" alt="WARNING"
     width="25" height="25">
<img src="http://kubernetes.io/img/warning.png" alt="WARNING"
     width="25" height="25">
<img src="http://kubernetes.io/img/warning.png" alt="WARNING"
     width="25" height="25">

<h2>PLEASE NOTE: This document applies to the HEAD of the source tree</h2>

If you are using a released version of Kubernetes, you should
refer to the docs that go with that version.

<strong>
The latest release of this document can be found
[here](http://releases.k8s.io/release-1.1/docs/proposals/workflow.md).

Documentation for other releases can be found at
[releases.k8s.io](http://releases.k8s.io).
</strong>
--

<!-- END STRIP_FOR_RELEASE -->

<!-- END MUNGE: UNVERSIONED_WARNING -->


## Abstract

A proposal to introduce [workflow](https://en.wikipedia.org/wiki/Workflow_management_system)
functionality in kubernetes.
Workflows (aka [DAG](https://en.wikipedia.org/wiki/Directed_acyclic_graph) workflows
since _tasks_ are organized in a Directed Acyclic Graph) are ubiquitous
in modern [job schedulers](https://en.wikipedia.org/wiki/Job_scheduler), see for example:

* [luigi](https://github.com/spotify/luigi)
* [ozie](http://oozie.apache.org/)
* [azkaban](https://azkaban.github.io/)

Most of the [job schedulers](https://en.wikipedia.org/wiki/List_of_job_scheduler_software) offer
workflow functionality to some extent.


## Use Cases

* As a user I want to be able to define a workflow.
* As a user I want to compose workflows.
* As a user I want to delete a workflow (eventually cascading to running _tasks_).
* As a user I want to debug a workflow (ability to track failure).



### Initializers

In order to implement `Workflow`, one need to introduce the concept of _dependency_ between resources.
Dependecies are _edges_ of the graph.
_Dependecy_ are introduced by [initializers proposal #17305](https://github.com/kubernetes/kubernetes/pull/17305) as well.
An _initializer_ is a dynamically registered object which implements a custom policy.
The policy could be based on some dependencies. The  policy is applied before the resource is
created (even API validated).
Modifying the policy one may  defer creation of the resource until prerequisites are satisfied.
Even if not completed [#17305](https://github.com/kubernetes/kubernetes/pull/17305) already introduces a
_dependecy_ concept [see](https://github.com/kubernetes/kubernetes/pull/17305#discussion_r45007826)
which could be reused to implement `Workflow`.

```go
type ObjectDependencies struct {
    Initializers map[string]string `json:"initializers,omitempty"`
    Finalizers map[string]string `json:"finalizers,omitempty"`
    ExistenceDependencies []ObjectReference `json:"existenceDependencies,omitempty"`
    ControllerRef *ObjectReference `json:"controllerRef,omitempty"`
...
}
```

### Recurring `Workflow` and `scheduledJob`

One of the major functionality is missing here is the ability to set a recurring `Workflow` (cron-like),
similar to the ScheduledJob [#11980](https://github.com/kubernetes/kubernetes/pull/11980) for `Job`.
If the the scheduled job will be able
to support [different resources](https://github.com/kubernetes/kubernetes/pull/11980#discussion_r46729699)
`Workflow` will benefit of _schedule_ functionality of `Job`.


### Graceful and immediate termination

`Workflow` should support _graceful and immediate termination_ [#1535](https://github.com/kubernetes/kubernetes/issues/1535).


## Implementation

This proposal introduces a new REST resource `Workflow`. A `Workflow` is represented as
[graph](https://en.wikipedia.org/wiki/Graph_(mathematics)), more specifically as a DAG.
Vertices of the graph represent steps of the workflow. The workflow steps are represented via a
`WorkflowStep` resource.
The edges of the graph are not represented explicitally but they are stored as a list of
predecessors in each `WorkflowStep` (i.e. each node).


### Workflow

A new resource will be introduced in API. A `Workflow` is a graph.
In the simplest case it's a a graph of `Job` but it can also
be a graph of other entity (for example cross-cluster object or others `Workflow`).


```go
// Workflow is a directed acyclic graph
type Workflow struct {
    unversioned.TypeMeta `json:",inline"`

    // Standard object's metadata.
	// More info: http://releases.k8s.io/HEAD/docs/devel/api-conventions.md#metadata.
	api.ObjectMeta `json:"metadata,omitempty"`

    // Spec defines the expected behavior of a Workflow. More info: http://releases.k8s.io/HEAD/docs/devel/api-conventions.md#spec-and-status.
    Spec WorkflowSpec `json:"spec,omitempty"`

    // Status represents the current status of the Workflow. More info: http://releases.k8s.io/HEAD/docs/devel/api-conventions.md#spec-and-status.
    Status WorkflowStatus `json:"status,omitempty"`
}
```


#### `WorkflowSpec`

```go
// WorkflowSpec contains Workflow specification
type WorkflowSpec struct {

    // Optional duration in seconds the workflow needs to terminate gracefully. May be decreased in delete request.
	// Value must be non-negative integer. The value zero indicates delete immediately.
	// If this value is nil, the default grace period will be used instead.
	// Set this value longer than the expected cleanup time for your workflow.
    // If downstream resources (job, pod, etc.) define their TerminationGracePeriodSeconds
    // the biggest is taken.
	TerminationGracePeriodSeconds *int64 `json:"terminationGracePeriodSeconds,omitempty"`

	// Steps contains the vertices of the workflow graph.
	Steps []WorkflowStep `json:"steps,omitempty"`
}
```

* `spec.steps`: is an array of `WorkflowStep`s.
* `spec.terminationGracePeriodSeconds`: is the terminationGracePeriodSeconds.

### `WorkflowStep`<sup>1</sup>

The `WorkflowStep` resource acts as a [union](https://en.wikipedia.org/wiki/Tagged_union) of `JobSpec` and `ObjectReference`.

```go
// WorkflowStep contains necessary information to identifiy the node of the workflow graph
type WorkflowStep struct {
    // Id is the identifier of the current step
    Id string  `json:"id,omitempty"`

    // Spec contains the job specificaton that should be run in this Workflow.
	// Only one between External and Spec can be set.
	Spec JobSpec `json:"jobSpec,omitempty"`

    // Dependecies represent dependecies of the current workflow step
    Dependencies ObjectDependencies `json:"dependencies,omitempty"`

	// External contains a reference to another schedulable resource.
	// Only one between ExternalRef and Spec can be set.
	ExternalRef api.ObjectReference `json:"externalRef,omitempty"`
}
```

* `workflowStep.id` is a string to identify the current `Workflow`. The `workfowStep.id` is injected
as a label in `metadata.annotations` in the `Job` created in the current step.
* `workflowStep.jobSpec` contains the specification of the job to be executed.
* `workflowStep.externalRef` contains a reference to external resources (for example another `Workflow`).

```go
type ObjectDependencies struct {
    ...
    ...
    ExistenceDependencies []ObjectReference `json:"existenceDependencies,omitempty"`
    ControllerRef *ObjectReference `json:"controllerRef,omitempty"`
    ...
}
```

### `WorkflowStatus`

```go
// WorkflowStatus contains the current status of the Workflow
type WorkflowStatus struct {
	Statuses []WorkflowStepStatus `json:statuses`
}

// WorkflowStepStatus contains the status of a WorkflowStep
type WorkflowStepStatus struct {
	// Job contains the status of Job for a WorkflowStep
	JobStatus Job `json:"jobsStatus,omitempty"`

	// External contains the
	ExternalRefStatus api.ObjectReference `json:"externalRefStatus,omitempty"`
}

// WorkflowList implements list of Workflow.
type WorkflowList struct {
	unversioned.TypeMeta `json:",inline"`
	// Standard list metadata
	// More info: http://releases.k8s.io/HEAD/docs/devel/api-conventions.md#metadata
	unversioned.ListMeta `json:"metadata,omitempty"`

	// Items is the list of Workflow
	Items []Workflow `json:"items"`
}
```

* `workfloStepStatus.jobStatus`: it contains the `Job` information to report current status of the _step_.

## Events

The events associated to `Workflow`s will be:

* WorkflowCreated
* WorkflowStarted
* WorkflowEnded

## Relevant use cases out of this proposal

* As an admin I want to set quota on workflow resources
[#13567](https://github.com/kubernetes/kubernetes/issues/13567).
* As an admin I want to re-assign a workflow resource to another namespace/user<sup>2</sup>.
* As a user I want to set an action when a workflow ends/start
[#3585](https://github.com/kubernetes/kubernetes/issues/3585)

<sup>1</sup>Something about naming: literature is full of different names, a commonly used
name is: _task_ but since we plan to compose `Workflow`s (i.e. a task can execute
another whole `Workflow`) the more generic word `Step` has been choosen.
<sup>2</sup>A very common feature in industrial strength workflow tools.

<!-- BEGIN MUNGE: GENERATED_ANALYTICS -->
[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/docs/proposals/workflow.md?pixel)]()
<!-- END MUNGE: GENERATED_ANALYTICS -->
