package utils

import (
	"fmt"
	"os"
	"strings"
	"path"
)

func FilterEnvs(envs []string, preservedKeys []string) []string {
	filteredEnvs := []string{}
	for _, entry := range envs {
		var kept bool = false
		for _, key := range preservedKeys {
			if strings.HasPrefix(entry, key+"=") {
				kept = true
				break
			}
		}
		if kept {
			filteredEnvs = append(filteredEnvs, entry)
		}
	}
	return filteredEnvs
}

func GetExecutable(pid int) (string, error) {
	const deletedTag = " (deleted)"
	execPath, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return execPath, err
	}
	execPath = strings.TrimSuffix(execPath, deletedTag)
	execPath = strings.TrimPrefix(execPath, deletedTag)
	switch execPath {
	case "/bin/sh", "/bin/bash", "/bin/dash":
		rawData := make([]byte, 1024)
		file, err := os.Open(fmt.Sprintf("/proc/%d/cmdline", pid))
		if err != nil {
			return execPath, err
		}
		file.Read(rawData)
		file.Close()
		data := string(rawData[:])
		cmd := strings.Split(data, "\x00")
		if !path.IsAbs(cmd[1]) && cmd[1] != "/usr/bin/env" {
			cwd, err := os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
			if err != nil {
				return execPath, err
			}
			execPath = path.Join(cwd, cmd[1])
		} else {
			execPath = cmd[1]
		}
	}
	return execPath, nil
}


// vim: ts=4 sts=4 sw=4 noet
