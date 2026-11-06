// Package elastic reads the Elasticsearch cluster Rails searches (EsClient), for the counts
// and searches a ported page needs.
package elastic

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	// requestTimeout is EsClient's; a page's own deadline cuts it shorter.
	requestTimeout   = 15 * time.Second
	maxResponseBytes = 8 << 20
	// Page views share one host, which DefaultTransport would keep only 2 connections to.
	idleConnsPerHost = 16
)

type Client struct {
	base string
	http *http.Client
}

// New takes ELASTICSEARCH_HOST. It reads only an https URL with no credentials or path, the
// shape production uses: elasticsearch-transport reads others differently (an http URL
// without a port is 9200 there, for one).
func New(host string) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = idleConnsPerHost
	return NewWithClient(host, &http.Client{Timeout: requestTimeout, Transport: transport})
}

// NewWithClient is New with the HTTP client given, for a test server's certificate.
func NewWithClient(host string, hc *http.Client) (*Client, error) {
	u, err := url.Parse(host)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || strings.Trim(u.Path, "/") != "" || u.RawQuery != "" {
		return nil, errors.New("elastic: ELASTICSEARCH_HOST isn't an https URL with only a host")
	}
	return &Client{base: "https://" + u.Host, http: hc}, nil
}

// Search posts body to index's _search and decodes the response into out.
func (c *Client) Search(ctx context.Context, index string, body, out any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/"+url.PathEscape(index)+"/_search", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes+1))
	if err != nil {
		return err
	}
	if len(data) > maxResponseBytes {
		return errors.New("elastic: response too large")
	}
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("elastic: %s %d", index, res.StatusCode)
	}
	return json.Unmarshal(data, out)
}

// Count is a search's exact hits.total.value.
func (c *Client) Count(ctx context.Context, index string, query any) (int64, error) {
	var res struct {
		Hits struct {
			Total struct {
				Value    int64  `json:"value"`
				Relation string `json:"relation"`
			} `json:"total"`
		} `json:"hits"`
	}
	body := map[string]any{"query": query, "from": 0, "size": 0, "_source": false, "aggs": map[string]any{}, "track_total_hits": true}
	if err := c.Search(ctx, index, body, &res); err != nil {
		return 0, err
	}
	if res.Hits.Total.Relation != "eq" {
		return 0, errors.New("elastic: inexact total")
	}
	return res.Hits.Total.Value, nil
}
