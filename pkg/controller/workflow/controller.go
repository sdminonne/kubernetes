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
	"reflect"
	"time"

	"github.com/golang/glog"
	"k8s.io/kubernetes/pkg/api"
	"k8s.io/kubernetes/pkg/apis/extensions"
	"k8s.io/kubernetes/pkg/client/cache"
	"k8s.io/kubernetes/pkg/client/record"
	client "k8s.io/kubernetes/pkg/client/unversioned"
	"k8s.io/kubernetes/pkg/controller"
	"k8s.io/kubernetes/pkg/controller/framework"
	replicationcontroller "k8s.io/kubernetes/pkg/controller/replication"
	"k8s.io/kubernetes/pkg/runtime"
	"k8s.io/kubernetes/pkg/util"
	"k8s.io/kubernetes/pkg/util/workqueue"
	"k8s.io/kubernetes/pkg/watch"
)

type WorkflowController struct {
	kubeClient client.Interface
	//	podControl controller.PodControlInterface
	jobControl controller.JobControlInterface

	// To allow injection of updateWorkflowStatus for testing.
	updateHandler func(workflow *extensions.Workflow) error
	syncHandler   func(workflowKey string) error
	// podStoreSynced returns true if the pod store has been synced at least once.
	// Added as a member to the struct to allow injection for testing.
	podStoreSynced func() bool

	// A TTLCache of job creates/deletes each rc expects to see
	expectations controller.ControllerExpectationsInterface

	// A store of workflow, populated by the frameworkController
	workflowStore cache.StoreToWorkflowLister
	// Watches changes to all workflows
	frameworkController *framework.Controller

	// Store of job
	jobStore cache.StoreToJobLister
	// Watches changes to all worklows
	jobController *framework.Controller

	jobStoreSynced func() bool

	// Workflows that need to be updated
	queue *workqueue.Type

	recorder record.EventRecorder
}

func NewWorkflowController(kubeClient client.Interface, resyncPeriod controller.ResyncPeriodFunc) *WorkflowController {
	eventBroadcaster := record.NewBroadcaster()
	eventBroadcaster.StartLogging(glog.Infof)
	eventBroadcaster.StartRecordingToSink(kubeClient.Events(""))

	wc := &WorkflowController{
		kubeClient: kubeClient,
		jobControl: controller.WorkflowJobControl{
			KubeClient: kubeClient,
			Recorder:   eventBroadcaster.NewRecorder(api.EventSource{Component: "workflow-controller"}),
		},
		expectations: controller.NewControllerExpectations(),
		queue:        workqueue.New(),
		recorder:     eventBroadcaster.NewRecorder(api.EventSource{Component: "workflow-controller"}),
	}

	wc.workflowStore.Store, wc.frameworkController = framework.NewInformer(
		&cache.ListWatch{
			ListFunc: func(options api.ListOptions) (runtime.Object, error) {
				return wc.kubeClient.Extensions().Workflows(api.NamespaceAll).List(options)
			},
			WatchFunc: func(options api.ListOptions) (watch.Interface, error) {
				return wc.kubeClient.Extensions().Workflows(api.NamespaceAll).Watch(options)
			},
		},
		&extensions.Workflow{},
		replicationcontroller.FullControllerResyncPeriod,
		framework.ResourceEventHandlerFuncs{
			AddFunc: wc.enqueueController,
			UpdateFunc: func(old, cur interface{}) {
				if workflow := cur.(*extensions.Workflow); !isWorkflowFinished(workflow) {
					wc.enqueueController(workflow)
				}
			},
			DeleteFunc: wc.enqueueController,
		},
	)

	wc.jobStore.Store, wc.jobController = framework.NewInformer(
		&cache.ListWatch{
			ListFunc: func(options api.ListOptions) (runtime.Object, error) {
				return wc.kubeClient.Extensions().Jobs(api.NamespaceAll).List(options)
			},
			WatchFunc: func(options api.ListOptions) (watch.Interface, error) {
				return wc.kubeClient.Extensions().Jobs(api.NamespaceAll).Watch(options)
			},
		},
		&extensions.Job{},
		replicationcontroller.FullControllerResyncPeriod,
		framework.ResourceEventHandlerFuncs{
			AddFunc:    wc.addJob,
			UpdateFunc: wc.updateJob,
			DeleteFunc: wc.deleteJob,
		},
	)

	wc.updateHandler = wc.updateWorkflowStatus
	wc.syncHandler = wc.syncWorkflow
	wc.jobStoreSynced = wc.jobController.HasSynced
	return wc
}

// Run the main goroutine responsible for watching and syncing workflows.
func (w *WorkflowController) Run(workers int, stopCh <-chan struct{}) {
	defer util.HandleCrash()
	go w.frameworkController.Run(stopCh)
	go w.jobController.Run(stopCh)
	for i := 0; i < workers; i++ {
		go util.Until(w.worker, time.Second, stopCh)
	}
	<-stopCh
	glog.Infof("Shutting down Workflow Controller")
	w.queue.ShutDown()
}

// getJobWorkflow return the workflow managing the given job
func (w *WorkflowController) getJobWorkflow(job *extensions.Job) *extensions.Workflow {
	workflows, err := w.workflowStore.GetJobWorkflows(job)
	if err != nil {
		glog.V(4).Infof("No workflows found for job %v: %v", job.Name, err)
		return nil
	}
	if len(workflows) > 1 {
		glog.Errorf("user error! more than one workflow is selecting jobs with labels: %+v", job.Labels)
		//sort.Sort(byCreationTimestamp(jobs))
	}
	return &workflows[0]
}

// worker runs a worker thread that just dequeues items, processes them, and marks them done.
// It enforces that the syncHandler is never invoked concurrently with the same key.
func (w *WorkflowController) worker() {
	for {
		func() {
			key, quit := w.queue.Get()
			if quit {
				return
			}
			defer w.queue.Done(key)
			err := w.syncHandler(key.(string))
			if err != nil {
				glog.Errorf("Error syncing workflow: %v", err)
			}
		}()
	}
}

func (w *WorkflowController) syncWorkflow(key string) error {
	startTime := time.Now()
	defer func() {
		glog.V(4).Infof("Finished syncing workflow %q (%v)", key, time.Now().Sub(startTime))
	}()

	obj, exists, err := w.workflowStore.Store.GetByKey(key)
	if !exists {
		glog.V(4).Infof("Workflow has been deleted: %v", key)
		w.expectations.DeleteExpectations(key)
		return nil
	}
	if err != nil {
		glog.Errorf("Unable to retrieve workflow %v from store: %v", key, err)
		w.queue.Add(key)
		return err
	}
	workflow := *obj.(*extensions.Workflow)
	glog.V(4).Infof("Syncing workflow %v", workflow.Name)
	if !w.jobStoreSynced() {
		glog.V(4).Infof("Syncing workflow %v", workflow.Name)
		time.Sleep(100 * time.Millisecond)
		glog.Infof("Waiting for job controller to sync, requeuing workflow %v", workflow.Name)
		w.enqueueController(&workflow)
		return nil
	}

	// Check the expectations of the workflow
	workflowKey, err := controller.KeyFunc(&workflow)
	if err != nil {
		glog.Errorf("Couldn't get key for workflow %#v: %v", workflow, err)
		return err
	}
	workflowNeedsSync := w.expectations.SatisfiedExpectations(workflowKey)

	if workflow.Status.Statuses == nil {
		workflow.Status.Statuses = make(map[string]api.ObjectReference, len(workflow.Spec.Steps))
		//TODO: sdminonne StartTime must be updated
	}

	if workflowNeedsSync {
		glog.V(4).Infof("Workflow %v needs synch", workflow.Name)
		w.manageWorkflow(&workflow)
	} else {
		glog.V(4).Infof("Workflow %v doensn't need synch", workflow.Name)
	}

	// if status changed {

	//	 w.enqueueController(&workflow)
	//}
	return nil
}

// pastActiveDeadline checks if workflow has ActiveDeadlineSeconds field set and if it is exceeded.
func pastActiveDeadline(workflow *extensions.Workflow) bool {
	return false
}

func (w *WorkflowController) updateWorkflowStatus(workflow *extensions.Workflow) error {
	_, err := w.kubeClient.Extensions().Workflows(workflow.Namespace).UpdateStatus(workflow)
	return err
}

func isWorkflowFinished(w *extensions.Workflow) bool {
	for _, c := range w.Status.Conditions {
		if (c.Type == extensions.WorkflowComplete) && c.Status == api.ConditionTrue {
			return true
		}
	}
	return false
}

func (w *WorkflowController) enqueueController(obj interface{}) {
	key, err := controller.KeyFunc(obj)
	if err != nil {
		glog.Errorf("Couldn't get key for object %+v: %v", obj, err)
		return
	}
	w.queue.Add(key)
}

func (w *WorkflowController) addJob(obj interface{}) {
	job := obj.(*extensions.Job)
	glog.V(4).Infof("addJob %v", job.Name)
	if workflow := w.getJobWorkflow(job); workflow != nil {
		key, err := controller.KeyFunc(workflow)
		if err != nil {
			glog.Errorf("No key for workflow %#v: %v", workflow, err)
			return
		}
		w.expectations.CreationObserved(key)
		w.enqueueController(workflow)
	}
}

func (w *WorkflowController) updateJob(old, cur interface{}) {
	oldJob := old.(*extensions.Job)
	curJob := cur.(*extensions.Job)
	glog.V(4).Infof("updateJob old=%v, cur=%v ", oldJob.Name, curJob.Name)
	if api.Semantic.DeepEqual(old, cur) {
		glog.V(4).Infof("\t nothing to update")
		return
	}
	if workflow := w.getJobWorkflow(curJob); workflow != nil {
		w.enqueueController(workflow)
	}
	// in case of relabelling
	if !reflect.DeepEqual(oldJob.Labels, curJob.Labels) {
		if oldWorkflow := w.getJobWorkflow(oldJob); oldWorkflow != nil {
			w.enqueueController(oldWorkflow)
		}
	}
}

func (w *WorkflowController) deleteJob(obj interface{}) {
	job, ok := obj.(*extensions.Job)
	glog.V(4).Infof("deleteJob old=%v", job.Name)
	if !ok {
		glog.V(4).Infof("TODO: WorkflfowController.deleteJob not receive a job object")
		return
	}
	if workflow := w.getJobWorkflow(job); workflow != nil {
		key, err := controller.KeyFunc(obj)
		if err != nil {
			glog.Errorf("Couldn't get key for workflow %#v: %v", workflow, err)
			return
		}
		w.expectations.DeletionObserved(key)
		w.enqueueController(workflow)
	}
}

func (w *WorkflowController) manageWorkflow(workflow *extensions.Workflow) bool {
	glog.V(4).Infof("manage Workflow -> %v", workflow.Name)
	if workflow.Spec != nil {
		return w.manageWorkflowJob(workflow)
	}
	return w.manageWorkflowReference(workflow)

}

func (w *WorkflowController) manageWorkflowJob(workflow *extensions.Workflow) bool {
	updateNeeded := true
	key, err := controller.KeyFunc(workflow)
	if err != nil {
		glog.Errorf("Couldn't get key for workflow %#v: %v", workflow, err)
		return updateNeeded
	}
	glog.V(4).Infof("manageWorkflowJob -> %v", workflow.Name)
	for stepName, step := range workflow.Spec.Steps {
		glog.V(4).Infof("\t Step : %v", stepName)
		if _, ok := workflow.Status.Statuses[stepName]; ok {

		} else { // no Job create it
			//			wait := sync
			if err := w.jobControl.CreateJob(workflow.Namespace, step.JobTemplate, workflow, stepName); err != nil {
				defer util.HandleError(err)
				w.expectations.CreationObserved(key)
				updateNeeded = true
			}
		}
	}
	return updateNeeded
}

func (w *WorkflowController) manageWorkflowReference(workflow *extensions.Workflow) bool {
	glog.V(4).Infof("manageWorkflowReference -> %v to be implemented", workflow.Name)

	return false
}
