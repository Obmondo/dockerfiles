package utils

import (
	"context"
	"time"

	"github.com/go-co-op/gocron/v2"
)

func SetupCron(ctx context.Context, function func(), tag string, duration time.Duration) gocron.Scheduler {
	cron, _ := gocron.NewScheduler(gocron.WithLocation(time.UTC))
	cron.NewJob(
		gocron.DurationJob(duration),
		gocron.NewTask(func() {
			function()
		}),
		gocron.WithStartAt(gocron.WithStartImmediately()),
		gocron.WithTags(tag),
	)

	return cron
}
