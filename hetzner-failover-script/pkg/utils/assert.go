package utils

import (
	"context"
	"log/slog"
	"os"
)

// Panics if the given error isn't nil.
func AssertErrNil(ctx context.Context, err error, customErrorMessage string, attributes ...any) {
	if err == nil {
		return
	}

	slog.ErrorContext(ctx, customErrorMessage, slog.Any("err", err))
	os.Exit(1)
}

// Panics if the given value is false.
func Assert(ctx context.Context, value bool, errorMessage string, attributes ...any) {
	if value {
		return
	}

	slog.ErrorContext(ctx, errorMessage, attributes...)
	os.Exit(1)
}
