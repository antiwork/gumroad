// Package routemetrics sends each action's request and 5xx counts to CloudWatch once a minute.
// The go_web target groups carry every route, so their load balancer metrics can't show one
// route failing while license verification dwarfs it; these can.
package routemetrics

import (
	"context"
	"log/slog"
	"maps"
	"slices"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
)

const (
	Namespace = "Gumroad/go_web"
	interval  = time.Minute
	// A hung send would hold the next minutes' counts and land them as one spike.
	sendTimeout = interval / 2
	// The send at shutdown has to fit in the Nomad kill_timeout with the HTTP shutdown.
	finalSendTimeout = 2 * time.Second
)

// maxPerCall is PutMetricData's limit on MetricData entries.
var maxPerCall = 1000

type putter interface {
	PutMetricData(ctx context.Context, in *cloudwatch.PutMetricDataInput, opts ...func(*cloudwatch.Options)) (*cloudwatch.PutMetricDataOutput, error)
}

type Recorder struct {
	put    putter
	logger *slog.Logger
	now    func() time.Time

	mu sync.Mutex
	// Every action seen since start, so a quiet minute still sends zeros: missing data then
	// means the sending broke, which the heartbeat alarm watches for.
	counts map[string]counts
}

type counts struct{ requests, errors float64 }

func New(put putter, logger *slog.Logger) *Recorder {
	return &Recorder{put: put, logger: logger, now: time.Now, counts: map[string]counts{}}
}

// Record counts one answered request for action ("Controller#action"). A 5xx is a server
// error; a client that left (499) is not.
func (r *Recorder) Record(action string, status int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.counts[action]
	c.requests++
	if status >= 500 {
		c.errors++
	}
	r.counts[action] = c
}

// Run sends the counts every minute until ctx ends, then sends what is left.
func (r *Recorder) Run(ctx context.Context) {
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			final, cancel := context.WithTimeout(context.Background(), finalSendTimeout)
			r.Flush(final)
			cancel()
			return
		case <-tick.C:
			send, cancel := context.WithTimeout(ctx, sendTimeout)
			r.Flush(send)
			cancel()
		}
	}
}

// Flush sends the counts since the last send and starts them over. A failed send's counts
// are dropped.
func (r *Recorder) Flush(ctx context.Context) {
	r.mu.Lock()
	pending := maps.Clone(r.counts)
	for action := range r.counts {
		r.counts[action] = counts{}
	}
	r.mu.Unlock()
	if len(pending) == 0 {
		return
	}
	at := r.now()
	data := make([]types.MetricDatum, 0, 2*len(pending))
	for _, action := range slices.Sorted(maps.Keys(pending)) {
		dims := []types.Dimension{{Name: aws.String("Action"), Value: aws.String(action)}}
		c := pending[action]
		data = append(data,
			types.MetricDatum{MetricName: aws.String("Requests"), Dimensions: dims, Value: aws.Float64(c.requests), Unit: types.StandardUnitCount, Timestamp: aws.Time(at)},
			types.MetricDatum{MetricName: aws.String("ServerErrors"), Dimensions: dims, Value: aws.Float64(c.errors), Unit: types.StandardUnitCount, Timestamp: aws.Time(at)},
		)
	}
	for batch := range slices.Chunk(data, maxPerCall) {
		if _, err := r.put.PutMetricData(ctx, &cloudwatch.PutMetricDataInput{Namespace: aws.String(Namespace), MetricData: batch}); err != nil {
			r.logger.Warn("Could not send route metrics", "error", err.Error())
		}
	}
}
