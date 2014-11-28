/*
Copyright 2014 Google Inc. All rights reserved.

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

package cmd

import (
	"fmt"
	"io"

	"github.com/GoogleCloudPlatform/kubernetes/pkg/kubectl"
	"github.com/spf13/cobra"
)

func (f *Factory) NewCmdDeleteAll(out io.Writer) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "deleteall [-d directory] [-f filename] [-l labelSelector]",
		Short: "Delete all resources specified in a directory, filename or stdin",
		Long: `Delete all resources contained in JSON file specified in a directory, filename or stdin

JSON and YAML formats are accepted.

Examples:
  $ kubectl deleteall -d configs/
  <deletes all resources listed in JSON or YAML files, found recursively under the configs directory>

  $ kubectl deleteall -f config.json
  <deletees all resources listed in config.json>

  $ cat config.json | kubectl apply -f -
  <deletes all resources listed in config.json>`,
		Run: func(cmd *cobra.Command, args []string) {
			filename := GetFlagString(cmd, "filename")
			directory := GetFlagString(cmd, "directory")
			if (len(filename) == 0 && len(directory) == 0) || (len(filename) != 0 && len(directory) != 0) {
				usageError(cmd, "Must pass a directory or filename to delete")
			}

			files := []string{}
			if len(filename) != 0 {
				files = append(files, filename)

			} else {
				files = append(GetFilesFromDir(directory, ".json"), GetFilesFromDir(directory, ".yaml")...)
			}

			for _, filename := range files {
				mapping, namespace, name, _ := ResourceFromFile(filename, f.Typer, f.Mapper)
				client, err := f.Client(cmd, mapping)
				checkErr(err)

				err = kubectl.NewRESTHelper(client, mapping).Delete(namespace, name)
				checkErr(err)
				fmt.Fprintf(out, "%s\n", name)
			}
		},
	}
	cmd.Flags().StringP("directory", "d", "", "Directory of JSON or YAML files to use to update the resource")
	cmd.Flags().StringP("filename", "f", "", "Filename or URL to file to use to update the resource")
	return cmd
}
