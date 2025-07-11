package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/hetzner"
	"github.com/Obmondo/dockerfiles/hetzner-failover-script/pkg/utils"

	"github.com/go-co-op/gocron/v2"
)

func setupContext() (ctx context.Context, cancel context.CancelFunc) {
	// When the program receives any interruption / SIGKILL / SIGTERM signal, the cancel function is
	// automatically invoked. The cancel function is responsible for freeing all the resources
	// associated with the context.
	signals := []os.Signal{
		syscall.SIGINT,
		syscall.SIGTERM,
		syscall.SIGQUIT,
	}

	return signal.NotifyContext(context.Background(), signals...)
}

func prepare(ctx context.Context) (func(), string, time.Duration) {
	// Fetch the cron time interval to spin the cron from env
	timeIntervalStr := utils.GetRequiredEnv("CRON_TIME_INTERVAL")
	timeInterval, err := time.ParseDuration(timeIntervalStr)
	if err != nil {
		slog.ErrorContext(
			ctx,
			"Failed to parse CRON_TIME_INTERVAL",
			slog.String("value", timeIntervalStr),
			slog.String("err", err.Error()),
		)
		os.Exit(1)
	}

	// Set the arguments and configurations for pointing IPs for failover
	args := hetzner.PointFailoverIPToArgs{
		Robot: hetzner.Robot{
			Username: os.Getenv("HETZNER_ROBOT_USERNAME"),
			Password: os.Getenv("HETZNER_ROBOT_PASSWORD"),

			APIToken: os.Getenv("HETZNER_API_TOKEN"),
		},

		FailoverIP: utils.GetRequiredEnv("FAILOVER_IP"),
		ServerIP:   utils.GetRequiredEnv("SERVER_IP"),
	}

	function := func() {
		hetzner.PointFailoverIPToServer(ctx, args)
	}

	tag := "HetznerFailover"

	return function, tag, timeInterval
}

func shutdown(ctx context.Context, c gocron.Scheduler) {
	<-ctx.Done()
	slog.WarnContext(ctx, "shutting down services...", slog.String("reason", ctx.Err().Error()))

	c.Shutdown()
	slog.InfoContext(ctx, "stopped cron scheduler")
}

func main() {
	ctx, cancel := setupContext()
	defer cancel()

	// Start the cron
	function, tag, timeInterval := prepare(ctx)
	c := utils.SetupCron(ctx, function, tag, timeInterval)
	c.Start()

	// Graceful shutdown
	shutdown(ctx, c)
}
