package main

import (
	"context"
	"os"

	"github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/hetzner"
	"github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/utils"
)

func main() {
	hetzner.PointFailoverIPToServer(context.Background(), hetzner.PointFailoverIPToArgs{
		Robot: hetzner.Robot{
			Username: os.Getenv("HETZNER_ROBOT_USERNAME"),
			Password: os.Getenv("HETZNER_ROBOT_PASSWORD"),

			APIToken: os.Getenv("HETZNER_API_TOKEN"),
		},

		FailoverIP: utils.GetRequiredEnv("FAILOVER_IP"),
		ServerIP:   utils.GetRequiredEnv("SERVER_IP"),
	})
}
