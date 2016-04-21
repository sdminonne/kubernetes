/*
Copyright 2016 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package workflow

import (
	"testing"

	"k8s.io/kubernetes/pkg/api"
	"k8s.io/kubernetes/pkg/apis/extensions"
	"k8s.io/kubernetes/pkg/client/clientset_generated/internalclientset/fake"
	"k8s.io/kubernetes/pkg/client/testing/core"
	"k8s.io/kubernetes/pkg/controller"
	"k8s.io/kubernetes/pkg/watch"
)

var alwaysReady = func() bool { return true }

func newWorkflow() *extensions.Workflow {
	w := &extensions.Workflow{
		ObjectMeta: api.ObjectMeta{
			Name:      "mydag",
			Namespace: api.NamespaceDefault,
		},
		Spec: extensions.WorkflowSpec{
			Steps: map[string]extensions.WorkflowStep{
				"myJob": extensions.WorkflowStep{
					JobTemplate: &extensions.JobTemplateSpec{
						ObjectMeta: api.ObjectMeta{
							Labels: map[string]string{
								"foo": "bar",
							},
						},
						Spec: extensions.JobSpec{
							Template: api.PodTemplateSpec{
								ObjectMeta: api.ObjectMeta{
									Labels: map[string]string{
										"foo": "bar",
									},
								},
								Spec: api.PodSpec{
									Containers: []api.Container{
										{Image: "foo/bar"},
									},
								},
							},
						},
					},
				},
			},
		},
	}
	return w
}

func TestControllerSyncWorkflow(t *testing.T) {

}

func TestSyncWorkflowComplete(t *testing.T) {
}

func TestSyncWorkflowDelete(t *testing.T) {
}

func TestWatchWorkflows(t *testing.T) {

}

func TestIsWorkflowFinished(t *testing.T) {
	cases := []struct {
		name     string
		finished bool
		workflow *extensions.Workflow
	}{
		{
			name:     "Complete and True",
			finished: true,
			workflow: &extensions.Workflow{
				Status: extensions.WorkflowStatus{
					Conditions: []extensions.WorkflowCondition{
						{
							Type:   extensions.WorkflowComplete,
							Status: api.ConditionTrue,
						},
					},
				},
			},
		},
		{
			name:     "Failed and True",
			finished: true,
			workflow: &extensions.Workflow{
				Status: extensions.WorkflowStatus{
					Conditions: []extensions.WorkflowCondition{
						{
							Type:   extensions.WorkflowFailed,
							Status: api.ConditionTrue,
						},
					},
				},
			},
		},
		{
			name:     "Complete and False",
			finished: false,
			workflow: &extensions.Workflow{
				Status: extensions.WorkflowStatus{
					Conditions: []extensions.WorkflowCondition{
						{
							Type:   extensions.WorkflowComplete,
							Status: api.ConditionFalse,
						},
					},
				},
			},
		},
		{
			name:     "Failed and False",
			finished: false,
			workflow: &extensions.Workflow{
				Status: extensions.WorkflowStatus{
					Conditions: []extensions.WorkflowCondition{
						{
							Type:   extensions.WorkflowComplete,
							Status: api.ConditionFalse,
						},
					},
				},
			},
		},
	}

	for _, tc := range cases {
		if isWorkflowFinished(tc.workflow) != tc.finished {
			t.Errorf("%s - Expected %v got %v", tc.name, tc.finished, isWorkflowFinished(tc.workflow))
		}
	}

}

func TestWatchJobs(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	fakeWatch := watch.NewFake()
	clientset.PrependWatchReactor("*", core.DefaultWatchReactor(fakeWatch, nil))
	manager := NewWorkflowController(clientset, controller.NoResyncPeriodFunc)
	manager.jobStoreSynced = alwaysReady

	testWorkflow := newWorkflow()
	manager.workflowStore.Store.Add(testWorkflow)

}
