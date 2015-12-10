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
since jobs are organized in a Directed Acyclic Graph) are ubiquitous
in modern [job schedulers](https://en.wikipedia.org/wiki/Job_scheduler), see for example:

* [luigi](https://github.com/spotify/luigi)
* [ozie](http://oozie.apache.org/)
* [azkaban](https://azkaban.github.io/)

Most of the [job schedulers](https://en.wikipedia.org/wiki/List_of_job_scheduler_software) offer
workflow functionality to some extent.


## Use Cases

* As a user I want to be able to define a workflow
* As a user I want to schedule a workflow via an ISO8601 specification.
* As a user I want to compose workflows.
* As a user I want the ability to re-execute the workflow
* As a user I want to set a deadline on each stage of the workflow.
* As a user I want to add delay to a specific workflow
* As a user I want to add restart a workflow.
* As a user I want to delete a workflow (eventually cascading to running jobs).
* As a user I want to debug a workflow (ability to track failure, and to understand causalities).

## Related

* Initializer [#17305](https://github.com/kubernetes/kubernetes/pull/17305)
* Quota [#13567](https://github.com/kubernetes/kubernetes/issues/13567)


## Implementation

This proposal introduces a new REST resource `Workflow`. A `Workflow` is represented as
[graph](https://en.wikipedia.org/wiki/Graph_(mathematics)), more specifically as a DAG.
Vertices of the graph represent steps of the workflow.
Edges of the graph represent the dependencies between vertices.
Between two vertices only an edge is admitted (a `Workflow` is not a _multi-graph_).


### Workflow

A new resource will be introduced in API. A `Workflow` is
a graph of. In the simplest case it's a a graph of `Job` but it can also
be a graph of other entity (for example cross-cluster object or other `Workflow`).

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
// WorkflowStepIdentifer represents the name of the workflow step
type WorkflowStepIdentifer string

// WorkflowSpec contains Workflow specification
type WorkflowSpec struct {
	// Key of the selector added to Jobs to prevent overlapping
	UniqueLabelKey string `json:"uniqueLabelKey"`

	// Steps contains the vertices of the workflow graph.
	Steps map[WorkflowStepIdentifer]WorkflowStep `json:"vertices,omitempty"`
}

```

* `spec.uniqueLabelKey`: this string is the key of the label to prevent resource ownership clashing
It must be unique across the cluster. If not supplied k8s will generate one. It will
be considered a _user error_ to supply an already in use key.
* `spec.vertices`: is a map. The key of the map is a `WorkflowStepIdentifier`.
The value of the map is a `WorkfloStep`.


### `WorkflowStep`

```go
const (
	// WaitAllPredecessors policy will start the job
	// when all predecessors ran to complete
	WaitAllPredecessors PredecessorsTriggeringPolicy = "WaitAllPredecessors"

	// WaitAtLeastOnePredecessor policy wil start the job when at least
	// one predecessor ran to complete
	WaitAtLeastOnePredecessor PredecessorsTriggeringPolicy = "WaitAtLeastOnePredecessor"
)

// WorkflowStep contains necessary information for a node of the workflow
type WorkflowStep struct {
	// Spec contains the job specificaton that should be run in this Workflow.
	// Only one between External and Spec can be set.
	Spec JobSpec `json:"jobSpec,omitempty"`

	// Predecessors contains references to the Predecessors WorkflowStep
	Predecessors []WorkflowStepIdentifer `json:"predecessors,omitempty"`

	// TriggeringPolicy defines the policy to schedule the current Job.
	// It can be set only if Spec is set.
	TriggeringPolicy PredecessorsTriggeringPolicy `json:"triggeringPolicy,omitempty"`

	// External contains a reference to another schedulable resource.
	// Only one between External and Spec can be set.
	ExternalRef api.ObjectReference `json:"externalRef,omitempty"`
}

```

* `workfloStep.predecessors` is a slice of `WorkflowStepIdentifier`. They are
reference to the predecessor steps of the current one.
* `workflowStep..jobSpec` contains the Job spec to be ran.
* `workflowStep.externalRef` contains a reference to the external reference.
* `workflowStep.triggeringPolicy` policy to trigger current workflow step (job or external reference).


`


### `WorkflowStatus`

```go
// WorkflowStatus contains the current status of the Workflow
type WorkflowStatus struct {
	Statuses map[WorkflowStepIdentifer]WorkflowStepStatus `json:statuses`
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

### `JobConditionType`

```go
// These are valid conditions of a job.
const (
// JobWaiting means the job is waiting to be started
	JobWaiting JobConditionType = "Waiting"
)
```

* A new job condition will be added to `JobConditionType`.

## Events

The events associated to `Workflow`s will be:

* WorkflowCreated
* WorkflowStarted
* WorkflowEnded

## Relevant use cases out of this proposal

* As an admin I want to set quota on workflow resources per user.
* As an admin I want to set quota on workflow resources per namespace.
* As an admin I want to re-assign a workflow resoruce to another user.
* As an admin I want to re-assign a workflow resource to another namespace.
* As a user I want to set an action when a workflow ends
* As a user I want to set an action when a workflow starts


<!-- BEGIN MUNGE: GENERATED_ANALYTICS -->
[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/docs/proposals/workflow.md?pixel)]()
<!-- END MUNGE: GENERATED_ANALYTICS -->
