package railscache

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

// Binary protocol opcodes, as Dalli::Protocol::Binary::RequestFormatter::OPCODES.
const (
	opGet    = 0x00
	opSet    = 0x01
	opDelete = 0x04
)

const (
	statusOK       = 0
	statusNotFound = 1
)

// ConnectionManager's down_retry_delay: how long a server that refused a connection is
// skipped before the next attempt.
const downRetryDelay = 30 * time.Second

const maxIdleConns = 64

// Far past memcached's 1MB item limit: a body this big means the stream is out of sync,
// and no value worth porting inflates to it.
const maxBodyLen = 16 << 20

type server struct {
	name    string // ConnectionManager#name, which the continuum hashes
	network string
	addr    string
	weight  int

	idle      chan *conn
	mu        sync.Mutex
	downUntil time.Time
}

type conn struct {
	net.Conn
	r      *bufio.Reader
	reused bool // from the idle pool, where memcached may have closed it
}

func (s *server) init() { s.idle = make(chan *conn, maxIdleConns) }

func (s *server) down(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return now.Before(s.downUntil)
}

func (s *server) markDown(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.downUntil = now.Add(downRetryDelay)
}

// conn is Base#alive?: an open connection, or a new one unless the server was marked down
// within downRetryDelay. A dial cut short by the caller's ctx doesn't mark it down.
func (s *server) conn(dialCtx, ctx context.Context, now time.Time) (*conn, error) {
	select {
	case c := <-s.idle:
		c.reused = true
		return c, nil
	default:
	}
	return s.dial(dialCtx, ctx, now)
}

func (s *server) dial(dialCtx, ctx context.Context, now time.Time) (*conn, error) {
	if s.down(now) {
		return nil, fmt.Errorf("%w: %s", ErrServerDown, s.name)
	}
	// A dial with no time left would fail without the server having been asked.
	if dl, ok := dialCtx.Deadline(); ok && !now.Before(dl) {
		return nil, fmt.Errorf("railscache: %s: %w", s.name, os.ErrDeadlineExceeded)
	}
	var d net.Dialer
	nc, err := d.DialContext(dialCtx, s.network, s.addr)
	if err != nil {
		if ctx.Err() == nil {
			s.markDown(now)
		}
		return nil, fmt.Errorf("%w: %s: %v", ErrServerDown, s.name, err)
	}
	return &conn{Conn: nc, r: bufio.NewReader(nc)}, nil
}

func (s *server) release(c *conn) {
	select {
	case s.idle <- c:
	default:
		c.Close()
	}
}

type response struct {
	status uint16
	extras []byte
	value  []byte
}

// roundTrip sends one request as RequestFormatter.standard_request packs it (opaque and
// CAS 0) and reads its response. Any error leaves the connection closed.
func (s *server) roundTrip(ctx context.Context, c *conn, deadline time.Time, op byte, key string, extras, value []byte) (response, error) {
	if err := c.SetDeadline(deadline); err != nil {
		c.Close()
		return response{}, err
	}
	stop := context.AfterFunc(ctx, func() { c.SetDeadline(time.Unix(1, 0)) })
	resp, err := exchange(c, op, key, extras, value)
	if !stop() {
		err = errors.Join(err, ctx.Err())
	}
	if err != nil {
		c.Close()
		return response{}, fmt.Errorf("railscache: %s: %w", s.name, err)
	}
	s.release(c)
	return resp, nil
}

func exchange(c *conn, op byte, key string, extras, value []byte) (response, error) {
	bodyLen := len(extras) + len(key) + len(value)
	req := make([]byte, 24, 24+bodyLen)
	req[0] = 0x80
	req[1] = op
	binary.BigEndian.PutUint16(req[2:], uint16(len(key)))
	req[4] = byte(len(extras))
	binary.BigEndian.PutUint32(req[8:], uint32(bodyLen))
	req = append(req, extras...)
	req = append(req, key...)
	req = append(req, value...)
	if _, err := c.Write(req); err != nil {
		return response{}, err
	}

	var h [24]byte
	if _, err := io.ReadFull(c.r, h[:]); err != nil {
		return response{}, err
	}
	keyLen := int(binary.BigEndian.Uint16(h[2:]))
	extraLen := int(h[4])
	status := binary.BigEndian.Uint16(h[6:])
	total := int(binary.BigEndian.Uint32(h[8:]))
	if h[0] != 0x81 || h[1] != op || total > maxBodyLen || extraLen+keyLen > total {
		return response{}, fmt.Errorf("bad response header %x", h)
	}
	body := make([]byte, total)
	if _, err := io.ReadFull(c.r, body); err != nil {
		return response{}, err
	}
	return response{status: status, extras: body[:extraLen], value: body[extraLen+keyLen:]}, nil
}
