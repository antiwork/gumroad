package routemetrics

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
)

type fakePutter struct {
	calls []*cloudwatch.PutMetricDataInput
	err   error
}

// PutMetricData fails a canceled call as the SDK does, recording only the ones it would send.
func (f *fakePutter) PutMetricData(ctx context.Context, in *cloudwatch.PutMetricDataInput, _ ...func(*cloudwatch.Options)) (*cloudwatch.PutMetricDataOutput, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	f.calls = append(f.calls, in)
	return &cloudwatch.PutMetricDataOutput{}, f.err
}

func sent(f *fakePutter) map[string]float64 {
	got := map[string]float64{}
	for _, call := range f.calls {
		for _, d := range call.MetricData {
			got[aws.ToString(d.Dimensions[0].Value)+" "+aws.ToString(d.MetricName)] += aws.ToFloat64(d.Value)
		}
	}
	return got
}

func TestFlushSendsEachActionsRequestsAndServerErrors(t *testing.T) {
	put := &fakePutter{}
	r := New(put, slog.Default())
	at := time.Unix(1_800_000_000, 0)
	r.now = func() time.Time { return at }
	for _, status := range []int{200, 302, 404, 499, 500, 502} {
		r.Record("LinksController#show", status)
	}
	r.Record("ForeignWebhooksController#paypal", 200)
	r.Flush(context.Background())

	want := map[string]float64{
		"LinksController#show Requests": 6, "LinksController#show ServerErrors": 2,
		"ForeignWebhooksController#paypal Requests": 1, "ForeignWebhooksController#paypal ServerErrors": 0,
	}
	got := sent(put)
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %v, want %v (all: %v)", k, got[k], v, got)
		}
	}
	if len(put.calls) != 1 || aws.ToString(put.calls[0].Namespace) != Namespace || !put.calls[0].MetricData[0].Timestamp.Equal(at) {
		t.Errorf("calls %+v", put.calls)
	}

	// Counts start over after a send, and a quiet minute sends zeros for every action seen.
	put.calls = nil
	r.Flush(context.Background())
	if got := sent(put); len(got) != 4 || got["LinksController#show Requests"] != 0 || got["ForeignWebhooksController#paypal Requests"] != 0 {
		t.Errorf("quiet minute sent %v", got)
	}
}

func TestNothingIsSentBeforeTheFirstRequest(t *testing.T) {
	put := &fakePutter{}
	New(put, slog.Default()).Flush(context.Background())
	if len(put.calls) != 0 {
		t.Errorf("sent %d calls", len(put.calls))
	}
}

func TestFlushSplitsAtPutMetricDatasLimit(t *testing.T) {
	defer func(n int) { maxPerCall = n }(maxPerCall)
	maxPerCall = 4
	put := &fakePutter{}
	r := New(put, slog.Default())
	for _, a := range []string{"A#a", "B#b", "C#c"} {
		r.Record(a, 200)
	}
	r.Flush(context.Background())
	if len(put.calls) != 2 || len(put.calls[0].MetricData) != 4 || len(put.calls[1].MetricData) != 2 {
		t.Errorf("batches %d", len(put.calls))
	}
}

func TestAFailedSendIsLoggedAndDropped(t *testing.T) {
	var logs bytes.Buffer
	put := &fakePutter{err: errors.New("AccessDenied")}
	r := New(put, slog.New(slog.NewJSONHandler(&logs, nil)))
	r.Record("LinksController#show", 500)
	r.Flush(context.Background())
	if !strings.Contains(logs.String(), "Could not send route metrics") || !strings.Contains(logs.String(), `"level":"WARN"`) {
		t.Errorf("logs %s", logs.String())
	}
	put.err = nil
	put.calls = nil
	r.Flush(context.Background())
	if got := sent(put); got["LinksController#show ServerErrors"] != 0 {
		t.Errorf("the failed minute was resent: %v", got)
	}
}

func TestRunSendsWhatIsLeftWhenStopped(t *testing.T) {
	put := &fakePutter{}
	r := New(put, slog.Default())
	r.Record("LinksController#show", 200)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		r.Run(ctx)
		close(done)
	}()
	cancel()
	<-done
	if sent(put)["LinksController#show Requests"] != 1 {
		t.Errorf("sent %v", sent(put))
	}
}
