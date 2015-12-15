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

* As a user I want to be able to define a workflow.
* As a user I want to compose workflows.
* As a user I want to delete a workflow (eventually cascading to running jobs).
* As a user I want to debug a workflow (ability to track failure).


## Comunity discussions:





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
	// Steps contains the vertices of the workflow graph.
	Steps []WorkflowStep `json:"steps,omitempty"`
}
```

* `spec.steps`: is an array of `WorkflowStep`s.


### `WorkflowStep`<sup>1</sup>

The `WorkflowStep` resource acts as a [union](https://en.wikipedia.org/wiki/Union_type) of `JobSpec` and `ObjectReference`.

```go
const (
	// WaitAllPredecessors policy will start the job
	// when all predecessors ran to complete
	WaitAllPredecessors PredecessorsTriggeringPolicy = "WaitAllPredecessors"

	// WaitAtLeastOnePredecessor policy wil start the job when at least
	// one predecessor ran to complete
	WaitAtLeastOnePredecessor PredecessorsTriggeringPolicy = "WaitAtLeastOnePredecessor"
)

// WorkflowStep contains necessary information to identifiy the node of the workflow graph
type WorkflowStep struct {
    // Id is the identifier of the current step
    Id string  `json:"id,omitempty"`

    // Spec contains the job specificaton that should be run in this Workflow.
	// Only one between External and Spec can be set.
	Spec JobSpec `json:"jobSpec,omitempty"`

	// Predecessors contains references to the Id of the current WorkflowStep predecessors
	Predecessors []string `json:"predecessors,omitempty"`

	// TriggeringPolicy defines the policy to schedule the current Job.
	// It can be set only if Spec is set.
	TriggeringPolicy PredecessorsTriggeringPolicy `json:"triggeringPolicy,omitempty"`

	// External contains a reference to another schedulable resource.
	// Only one between External and Spec can be set.
	ExternalRef api.ObjectReference `json:"externalRef,omitempty"`
}
```

* `workflowStep.id` is a string to identify the current `Workflow`. The `workfowStep.id` is injected
as a label in `metadata.annotations` in the `Job` created in the current step.
* `workflowStep.predecessors` is a slice of string. They are `id`s of to the predecessor steps.
* `workflowStep.jobSpec` contains the specification of the job to be executed.
* `workflowStep.externalRef` contains a reference to external resources (for example another `Workflow`).
The only requirement an the `externalRef` resource should have to be referenced is the ability to report the _complete_ status.
* `workflowStep.triggeringPolicy` policy to trigger current workflow step (job or external reference).


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

## Interaction with other community discussion


### Recurring `Workflow`

One of the major functionality is missing here is the ability to set a recurring `Workflow` (cron-like),
similar to the ScheduledJob [#11980](https://github.com/kubernetes/kubernetes/pull/11980) for `Job`.
If the the scheduled job will be able to support different resources ([see]

### Initializers

[Initializer proposal #17305](https://github.com/kubernetes/kubernetes/pull/17305) is still under dicussion but the idea will be


### Graceful and immediate termination

`Workflow` should support _graceful and immediate termination_ [#1535](https://github.com/kubernetes/kubernetes/issues/1535).


<sup>1</sup>Something about naming: literature is full of different names, a commonly used
name is: _task_ but since we plan to compose `Workflow`s (i.e. a task can execute
another whole `Workflow`) the more generic word `Step` has been choosen.
<sup>2</sup>A very common feature in industrial strength workflow tools.

<!-- BEGIN MUNGE: GENERATED_ANALYTICS -->
[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/docs/proposals/workflow.md?pixel)]()
<!-- END MUNGE: GENERATED_ANALYTICS -->
