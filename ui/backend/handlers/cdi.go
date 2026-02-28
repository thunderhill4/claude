package handlers

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var dvGVR = schema.GroupVersionResource{
	Group:    "cdi.kubevirt.io",
	Version:  "v1beta1",
	Resource: "datavolumes",
}

type DVImage struct {
	Name        string `json:"name"`
	Namespace   string `json:"namespace"`
	Phase       string `json:"phase"`      // Succeeded | ImportInProgress | Failed | ...
	Progress    string `json:"progress"`   // "100.0%" | "N/A"
	SourceType  string `json:"sourceType"` // upload | pvc | http | registry | blank
	Size        string `json:"size"`
	ClaimName   string `json:"claimName"`
	Age         string `json:"age"`
	ClusterName string `json:"clusterName"` // non-empty if owned by a CAPI cluster
}

// GET /api/v1/images
func HandleCDIImages(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	ns := r.URL.Query().Get("namespace")

	list, err := k8sclient.DynamicClient.Resource(dvGVR).Namespace(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing DataVolumes: %v", err)
		writeJSON(w, []DVImage{})
		return
	}

	images := make([]DVImage, 0, len(list.Items))
	for _, item := range list.Items {
		img := DVImage{
			Name:      item.GetName(),
			Namespace: item.GetNamespace(),
		}

		// CAPI cluster ownership label
		labels := item.GetLabels()
		img.ClusterName = labels["cluster.x-k8s.io/cluster-name"]

		// Spec: source type and storage size
		if spec, ok := item.Object["spec"].(map[string]interface{}); ok {
			if src, ok := spec["source"].(map[string]interface{}); ok {
				for k := range src {
					img.SourceType = k
					break
				}
			}
			if st, ok := spec["storage"].(map[string]interface{}); ok {
				if res, ok := st["resources"].(map[string]interface{}); ok {
					if req, ok := res["requests"].(map[string]interface{}); ok {
						if s, ok := req["storage"].(string); ok {
							img.Size = s
						}
					}
				}
			}
		}

		// Status: phase, progress, claimName
		if status, ok := item.Object["status"].(map[string]interface{}); ok {
			if p, ok := status["phase"].(string); ok {
				img.Phase = p
			}
			if p, ok := status["progress"].(string); ok {
				img.Progress = p
			}
			if c, ok := status["claimName"].(string); ok {
				img.ClaimName = c
			}
		}

		img.Age = ageFromTime(item.GetCreationTimestamp().Time)
		images = append(images, img)
	}

	writeJSON(w, images)
}

func ageFromTime(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}
