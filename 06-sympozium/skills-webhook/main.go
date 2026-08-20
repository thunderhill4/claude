// skills-webhook: mutating admission webhook that injects a default skill
// sidecar into task-mode AgentRuns created without one.
//
// Why: on Sympozium 0.10.38 nothing propagates an agent's skills into the
// AgentRuns spawned on its behalf — the dashboard chat (POST /api/v1/runs)
// silently drops any "skills" field in the request, SympoziumSchedules never
// copy skills, and the Agent CRD has no skills field to inherit from. A run
// without spec.skills gets only the agent + ipc-bridge containers, so every
// execute_command tool call is written to the IPC channel and never answered;
// the model eventually reports a "skill sidecar" problem as its final answer
// (see 06-sympozium/labs/02-agentrun/agentrun.yaml).
//
// This webhook patches spec.skills onto CREATEd AgentRuns when spec.mode ==
// "task", spec.skills is empty, and spec.agentRef is known. The SkillPack to
// inject is chosen per agent via $INJECT_SKILL_MAP (comma list of
// agentRef=skillPackRef pairs), e.g.:
//   cluster2-agent=k8s-ops,target-cluster-agent=target-k8s-ops
// cluster2-agent gets k8s-ops (in-cluster SA → cluster2 API); target-cluster-
// agent gets target-k8s-ops (mounts the target kubeconfig → reaches inside the
// target k3s cluster). Runs that declare their own skills (labs, the
// web-endpoint serving run, ensembles that set them) are untouched.
package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

type admissionReview struct {
	APIVersion string             `json:"apiVersion"`
	Kind       string             `json:"kind"`
	Request    *admissionRequest  `json:"request,omitempty"`
	Response   *admissionResponse `json:"response,omitempty"`
}

type admissionRequest struct {
	UID    string          `json:"uid"`
	Object json.RawMessage `json:"object"`
}

type admissionResponse struct {
	UID       string `json:"uid"`
	Allowed   bool   `json:"allowed"`
	PatchType string `json:"patchType,omitempty"`
	Patch     string `json:"patch,omitempty"`
}

type agentRun struct {
	Metadata struct {
		GenerateName string `json:"generateName"`
		Name         string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		AgentRef string        `json:"agentRef"`
		Mode     string        `json:"mode"`
		Skills   []interface{} `json:"skills"`
	} `json:"spec"`
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// parseSkillMap turns "a=x,b=y" into {a:x, b:y}, skipping malformed entries.
func parseSkillMap(s string) map[string]string {
	m := map[string]string{}
	for _, pair := range strings.Split(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if k = strings.TrimSpace(k); ok && k != "" {
			m[k] = strings.TrimSpace(v)
		}
	}
	return m
}

func main() {
	skillMap := parseSkillMap(getenv("INJECT_SKILL_MAP",
		"cluster2-agent=k8s-ops,target-cluster-agent=target-k8s-ops"))

	http.HandleFunc("/mutate", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "read error", http.StatusBadRequest)
			return
		}
		var review admissionReview
		if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
			http.Error(w, "not an AdmissionReview", http.StatusBadRequest)
			return
		}

		resp := &admissionResponse{UID: review.Request.UID, Allowed: true}
		var run agentRun
		if err := json.Unmarshal(review.Request.Object, &run); err == nil &&
			run.Spec.Mode == "task" && len(run.Spec.Skills) == 0 {
			if skill := skillMap[run.Spec.AgentRef]; skill != "" {
				patch, _ := json.Marshal([]map[string]interface{}{{
					"op":    "add",
					"path":  "/spec/skills",
					"value": []map[string]string{{"skillPackRef": skill}},
				}})
				resp.PatchType = "JSONPatch"
				resp.Patch = base64.StdEncoding.EncodeToString(patch)
				log.Printf("injected skillPackRef=%s into AgentRun %s%s (agentRef=%s)",
					skill, run.Metadata.GenerateName, run.Metadata.Name, run.Spec.AgentRef)
			}
		}

		review.Response = resp
		review.Request = nil
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(review)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Printf("skills-webhook listening on :8443 (skillMap=%v)", skillMap)
	log.Fatal(http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil))
}
