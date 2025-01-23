package hetzner

import (
	"context"
	"encoding/json"
	"log"
	"log/slog"
	"net/http"

	assert "github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/utils"
	"github.com/go-resty/resty/v2"
)

const HETZNER_ROBOT_WEB_SERVICE_API = "https://robot-ws.your-server.de"

type (
	PointFailoverIPToArgs struct {
		Robot Robot
		FailoverIP,
		ServerIP string
	}

	Robot struct {
		APIToken,

		Username,
		Password string
	}
)

// Makes the given Failover IP point to the server IP.
func PointFailoverIPToServer(ctx context.Context, args PointFailoverIPToArgs) {
	httpClient := resty.New().
		SetBaseURL(HETZNER_ROBOT_WEB_SERVICE_API)

	switch {
	case len(args.Robot.Username) > 0 && len(args.Robot.Password) > 0:
		httpClient.SetBasicAuth(args.Robot.Username, args.Robot.Password)

	case len(args.Robot.APIToken) > 0:
		httpClient.SetAuthToken(args.Robot.APIToken)

	default:
		log.Fatalf("Either provide username and password / api token as credentials, to communicate with the Hetzner Robot API")
	}

	/*
		A Failover IP is an additional IP that you can switch from one server to another. You can order
		it for any Hetzner dedicated root server, and you can switch it to any other Hetzner dedicated
		root server, regardless of location.

		Switching a Failover IP takes between 90 and 110 seconds.

		REFERENCE : https://docs.hetzner.com/robot/dedicated-server/ip/failover/.
	*/
	// Hetzner Robot Failover IP API spec : https://robot.hetzner.com/doc/webservice/en.html#failover.

	// Get IP address of the server, the Failover IP is currently pointing to.
	activeServerIP := getActiveServerIP(ctx, httpClient, args.FailoverIP)
	slog.InfoContext(ctx, "Detected active server", slog.String("ip", activeServerIP))

	if activeServerIP == args.ServerIP {
		slog.InfoContext(ctx, "Active server IP is already same as the current server IP")
		return
	}

	// Update Failover IP to the current node's IP (the current node, on which this script is
	// running)
	switchFailoverIP(ctx, httpClient, args.FailoverIP, args.ServerIP)
}

type (
	GetFailoverResponse struct {
		Failover struct {
			ActiveServerIP string `json:"active_server_ip"`
		} `json:"failover"`
	}
)

// Returns the IP address of the server, the given Failover IP is pointing to.
func getActiveServerIP(ctx context.Context, httpClient *resty.Client, failoverIP string) string {
	response, err := httpClient.NewRequest().
		SetHeader("Accept", "application/json").
		Get("/failover/" + failoverIP)

	assert.AssertErrNil(ctx, err, "Failed getting Failover IP details")
	assert.Assert(ctx, response.StatusCode() == http.StatusOK, "Failed getting Failover IP details")

	var unmarshalledResponse GetFailoverResponse
	err = json.Unmarshal(response.Body(), &unmarshalledResponse)
	assert.AssertErrNil(ctx, err, "Failed unmarshalling Failover IP details")

	return unmarshalledResponse.Failover.ActiveServerIP
}

// Makes the Failover IP point to the given server.
func switchFailoverIP(ctx context.Context, httpClient *resty.Client, failoverIP, targetServerIP string) {
	response, err := httpClient.NewRequest().
		SetHeader("Content-Type", "application/x-www-form-urlencoded").
		SetFormData(map[string]string{
			"active_server_ip": targetServerIP,
		}).
		SetHeader("Accept", "application/json").
		Post("/failover/" + failoverIP)

	assert.AssertErrNil(ctx, err, "Failed switching Failover IP to the current node IP")
	assert.Assert(ctx,
		response.StatusCode() == http.StatusOK,
		"Failed switching Failover IP to the current node IP",
		slog.Any("response", response),
	)

	slog.InfoContext(ctx,
		"Successfully updated Failover IP",
		slog.String("active-server-ip", targetServerIP),
	)
}
