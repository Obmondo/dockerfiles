package hetzner

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/kube"
	"github.com/go-resty/resty/v2"
)

const HETZNER_ROBOT_WEB_SERVICE_API = "https://robot-ws.your-server.de"

type (
	PointFailoverIPToArgs struct {
		Robot Robot
		FailoverIP,
		NodeName string
	}

	Robot struct {
		APIToken,

		Username,
		Password string
	}
)

/*
	A Failover IP is an additional IP that you can switch from one server to another. You can order
	it for any Hetzner dedicated root server, and you can switch it to any other Hetzner dedicated
	root server, regardless of location.

	Switching a Failover IP takes between 90 and 110 seconds.

	REFERENCE : https://docs.hetzner.com/robot/dedicated-server/ip/failover/.

	Hetzner Robot Failover IP API spec : https://robot.hetzner.com/doc/webservice/en.html#failover.
*/

// PointFailoverIPToServer makes the given Failover IP point to the public IP of the node this pod
// is running on.
//
// Errors are returned (not fatal) so the caller can log and retry on the next interval, instead of
// crash-looping the process on a transient or misconfigured API call.
func PointFailoverIPToServer(ctx context.Context, args PointFailoverIPToArgs) error {
	httpClient := resty.New().
		SetBaseURL(HETZNER_ROBOT_WEB_SERVICE_API)

	switch {
	case len(args.Robot.Username) > 0 && len(args.Robot.Password) > 0:
		httpClient.SetBasicAuth(args.Robot.Username, args.Robot.Password)

	case len(args.Robot.APIToken) > 0:
		httpClient.SetAuthToken(args.Robot.APIToken)

	default:
		return fmt.Errorf("no Hetzner Robot credentials provided: set a username and password, or an API token")
	}

	// The Robot Failover API only accepts the target server's public main IP as active_server_ip.
	// Resolve this node's ExternalIP (its public main IP) from the Kubernetes API. This is NOT the
	// same as the pod's status.hostIP, which is the private vSwitch IP when kubelet runs with
	// --node-ip set to the internal network.
	targetServerIP, err := kube.GetNodeExternalIP(ctx, args.NodeName)
	if err != nil {
		return fmt.Errorf("resolving the public IP of node %q: %w", args.NodeName, err)
	}

	// Get the IP address of the server the Failover IP currently points to.
	activeServerIP, err := getActiveServerIP(ctx, httpClient, args.FailoverIP)
	if err != nil {
		return err
	}
	slog.InfoContext(ctx, "Detected active server",
		slog.String("ip", activeServerIP),
		slog.String("node", args.NodeName),
		slog.String("nodeExternalIP", targetServerIP),
	)

	if activeServerIP == targetServerIP {
		slog.InfoContext(ctx, "Failover IP already points to this node's public IP; nothing to do")
		return nil
	}

	// Update the Failover IP to the current node's public IP.
	return switchFailoverIP(ctx, httpClient, args.FailoverIP, targetServerIP)
}

type GetFailoverResponse struct {
	Failover struct {
		ActiveServerIP string `json:"active_server_ip"`
	} `json:"failover"`
}

// getActiveServerIP returns the IP address of the server the given Failover IP points to.
func getActiveServerIP(ctx context.Context, httpClient *resty.Client, failoverIP string) (string, error) {
	response, err := httpClient.NewRequest().
		SetContext(ctx).
		SetHeader("Accept", "application/json").
		Get("/failover/" + failoverIP)
	if err != nil {
		return "", fmt.Errorf("getting Failover IP %q details: %w", failoverIP, err)
	}
	if response.StatusCode() != http.StatusOK {
		return "", fmt.Errorf("getting Failover IP %q details: unexpected status %d: %s",
			failoverIP, response.StatusCode(), response.String())
	}

	var unmarshalledResponse GetFailoverResponse
	if err := json.Unmarshal(response.Body(), &unmarshalledResponse); err != nil {
		return "", fmt.Errorf("decoding Failover IP %q details: %w", failoverIP, err)
	}

	return unmarshalledResponse.Failover.ActiveServerIP, nil
}

// switchFailoverIP makes the Failover IP point to the given server.
func switchFailoverIP(ctx context.Context, httpClient *resty.Client, failoverIP, targetServerIP string) error {
	response, err := httpClient.NewRequest().
		SetContext(ctx).
		SetHeader("Content-Type", "application/x-www-form-urlencoded").
		SetHeader("Accept", "application/json").
		SetFormData(map[string]string{
			"active_server_ip": targetServerIP,
		}).
		Post("/failover/" + failoverIP)
	if err != nil {
		return fmt.Errorf("switching Failover IP %q to %q: %w", failoverIP, targetServerIP, err)
	}
	if response.StatusCode() != http.StatusOK {
		return fmt.Errorf("switching Failover IP %q to %q: unexpected status %d: %s",
			failoverIP, targetServerIP, response.StatusCode(), response.String())
	}

	slog.InfoContext(ctx,
		"Successfully updated Failover IP",
		slog.String("active-server-ip", targetServerIP),
	)
	return nil
}
