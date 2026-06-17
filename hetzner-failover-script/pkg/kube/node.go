package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"

	"github.com/go-resty/resty/v2"
)

const (
	serviceAccountTokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	serviceAccountCAPath    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
)

// NodeAddress mirrors a single entry of a Kubernetes Node's status.addresses.
type NodeAddress struct {
	Type    string `json:"type"`
	Address string `json:"address"`
}

type nodeResponse struct {
	Status struct {
		Addresses []NodeAddress `json:"addresses"`
	} `json:"status"`
}

// SelectExternalIP returns the ExternalIP from a Node's status.addresses.
//
// For Hetzner dedicated (Robot) servers this is the server's public main IP —
// the only address the Robot Failover API accepts as active_server_ip. The
// node's status.hostIP, by contrast, is the (private) vSwitch IP when kubelet
// runs with --node-ip set to the internal network.
func SelectExternalIP(addresses []NodeAddress) (string, error) {
	for _, address := range addresses {
		if address.Type == "ExternalIP" {
			return address.Address, nil
		}
	}

	return "", fmt.Errorf("no ExternalIP found among %d node address(es)", len(addresses))
}

// GetNodeExternalIP looks up the given Node through the in-cluster Kubernetes
// API and returns its ExternalIP. It authenticates with the pod's mounted
// ServiceAccount token and verifies the API server against the mounted cluster
// CA, so the pod's ServiceAccount needs RBAC to "get" nodes.
func GetNodeExternalIP(ctx context.Context, nodeName string) (string, error) {
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if len(host) == 0 || len(port) == 0 {
		return "", fmt.Errorf("not running in-cluster: KUBERNETES_SERVICE_HOST / KUBERNETES_SERVICE_PORT are unset")
	}

	token, err := os.ReadFile(serviceAccountTokenPath)
	if err != nil {
		return "", fmt.Errorf("reading ServiceAccount token: %w", err)
	}

	httpClient := resty.New().
		SetBaseURL("https://" + net.JoinHostPort(host, port)).
		SetRootCertificate(serviceAccountCAPath).
		SetAuthToken(string(token))

	response, err := httpClient.NewRequest().
		SetContext(ctx).
		SetHeader("Accept", "application/json").
		Get("/api/v1/nodes/" + nodeName)
	if err != nil {
		return "", fmt.Errorf("requesting node %q from the Kubernetes API: %w", nodeName, err)
	}
	if response.StatusCode() != http.StatusOK {
		return "", fmt.Errorf("requesting node %q from the Kubernetes API: unexpected status %d: %s",
			nodeName, response.StatusCode(), response.String())
	}

	var node nodeResponse
	if err := json.Unmarshal(response.Body(), &node); err != nil {
		return "", fmt.Errorf("decoding node %q response: %w", nodeName, err)
	}

	externalIP, err := SelectExternalIP(node.Status.Addresses)
	if err != nil {
		return "", fmt.Errorf("node %q: %w", nodeName, err)
	}

	return externalIP, nil
}
