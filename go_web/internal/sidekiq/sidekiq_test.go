package sidekiq

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

var elasticsearchIndexer = Options{Class: "ElasticsearchIndexerWorker", Queue: "default", Retry: 10}

func TestPayloadMatchesSidekiqsKeyOrder(t *testing.T) {
	at := time.Unix(1730000000, 123456000)
	jid, payload, err := Payload(elasticsearchIndexer, []any{"index", Hash{{"class_name", "ProductPageView"}, {"id", "abc"}}}, at)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`\A[0-9a-f]{24}\z`).MatchString(jid) {
		t.Fatalf("jid = %q", jid)
	}
	want := `{"retry":10,"queue":"default","backtrace":true,"args":["index",{"class_name":"ProductPageView","id":"abc"}],` +
		`"class":"ElasticsearchIndexerWorker","jid":"` + jid + `","created_at":1730000000.123456,"enqueued_at":1730000000.123456}`
	if string(payload) != want {
		t.Fatalf("payload\n got %s\nwant %s", payload, want)
	}
}

func TestPayloadRefusesWhatSidekiqRefuses(t *testing.T) {
	if _, _, err := Payload(elasticsearchIndexer, []any{map[string]any{"a": 1}}, time.Now()); err == nil {
		t.Error("an unordered map must not be pushed")
	}
	if _, _, err := Payload(elasticsearchIndexer, []any{"bad \xff"}, time.Now()); err == nil {
		t.Error("JSON.generate raises on invalid UTF-8")
	}
	if _, _, err := Payload(elasticsearchIndexer, []any{json.Number("1e400")}, time.Now()); err == nil {
		t.Error("JSON.generate raises on Infinity")
	}
}

func TestPushRegistersTheQueueAndPushesLeft(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	c := &Client{Redis: client}

	first, err := c.Push(context.Background(), elasticsearchIndexer, "index", Hash{{"id", "1"}})
	if err != nil {
		t.Fatal(err)
	}
	second, _ := c.Push(context.Background(), elasticsearchIndexer, "index", Hash{{"id", "2"}})

	if members, _ := server.Members("queues"); len(members) != 1 || members[0] != "default" {
		t.Fatalf("queues = %v", members)
	}
	jobs, _ := server.List("queue:default")
	if len(jobs) != 2 {
		t.Fatalf("queue = %v", jobs)
	}
	// LPUSH: the newest job is at the head, and Sidekiq's BRPOP takes the oldest first.
	var head struct{ JID string }
	json.Unmarshal([]byte(jobs[0]), &head)
	if head.JID != second || first == second {
		t.Fatalf("head jid %s, pushed %s then %s", head.JID, first, second)
	}
}

func TestMarshalMatchesRubyJSONGenerate(t *testing.T) {
	data, err := os.ReadFile("testdata/ruby_json.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Value  json.RawMessage
		JSON   string
		Floats []string
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		decoder := json.NewDecoder(bytes.NewReader(c.Value))
		decoder.UseNumber()
		var value any
		if err := decoder.Decode(&value); err != nil {
			t.Fatal(err)
		}
		got, err := Marshal(ordered(value, c.Value))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != c.JSON {
			t.Errorf("Marshal\n got %s\nwant %s", got, c.JSON)
		}
		for i, want := range c.Floats {
			f, _ := value.([]any)[i].(json.Number).Float64()
			if s, _ := RubyFloat(f); s != want {
				t.Errorf("RubyFloat(%v) = %s, want %s", f, s, want)
			}
		}
	}
}

// ordered rebuilds a decoded object as a Hash in the fixture's key order.
func ordered(value any, raw json.RawMessage) any {
	object, ok := value.(map[string]any)
	if !ok {
		return value
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	decoder.Token()
	var h Hash
	for decoder.More() {
		key, _ := decoder.Token()
		var skip json.RawMessage
		decoder.Decode(&skip)
		h = append(h, Pair{key.(string), object[key.(string)]})
	}
	return h
}

func TestPushInSchedulesWithoutEnqueuedAt(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	at := time.Unix(1730000000, 500000000)
	c := &Client{Redis: client, Now: func() time.Time { return at }}

	jid, err := c.PushIn(context.Background(), elasticsearchIndexer, 2*time.Second, "update",
		Hash{{"record_id", 7}, {"class_name", "Purchase"}, {"fields", []any{"license_uses"}}})
	if err != nil {
		t.Fatal(err)
	}
	members, err := server.ZMembers("schedule")
	if err != nil || len(members) != 1 {
		t.Fatalf("schedule = %v %v", members, err)
	}
	want := `{"retry":10,"queue":"default","backtrace":true,"class":"ElasticsearchIndexerWorker",` +
		`"args":["update",{"record_id":7,"class_name":"Purchase","fields":["license_uses"]}],"jid":"` + jid + `","created_at":1730000000.5}`
	if members[0] != want {
		t.Fatalf("payload\n got %s\nwant %s", members[0], want)
	}
	if score, _ := server.ZScore("schedule", members[0]); score != 1730000002.5 {
		t.Errorf("score = %v", score)
	}
	if server.Exists("queue:default") {
		t.Error("a scheduled job must not reach the queue yet")
	}

	if _, err := c.PushIn(context.Background(), elasticsearchIndexer, 0, "index"); err != nil {
		t.Fatal(err)
	}
	if jobs, _ := server.List("queue:default"); len(jobs) != 1 || !strings.Contains(jobs[0], `"class":"ElasticsearchIndexerWorker","args":["index"]`) {
		t.Errorf("an interval that is not in the future pushes now: %v", jobs)
	}
}

func TestMarshalRefusesNestingPastJSONGenerate(t *testing.T) {
	var deep any = "x"
	for i := 0; i < 100; i++ {
		deep = []any{deep}
	}
	if _, err := Marshal(deep); err != nil {
		t.Fatalf("100 levels: %v", err)
	}
	if _, err := Marshal([]any{deep}); !errors.Is(err, ErrUnserializable) {
		t.Fatalf("101 levels: %v", err)
	}
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	if _, err := (&Client{Redis: client}).Push(context.Background(), elasticsearchIndexer, "bad \xff"); !errors.Is(err, ErrUnserializable) {
		t.Errorf("invalid UTF-8: %v", err)
	}
	server.Close()
	if _, err := (&Client{Redis: client}).Push(context.Background(), elasticsearchIndexer, "ok"); err == nil || errors.Is(err, ErrUnserializable) {
		t.Errorf("a Redis failure is not a serialization error: %v", err)
	}
}
