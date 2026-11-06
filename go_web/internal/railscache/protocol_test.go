package railscache

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

// fakeMemcached answers every binary request "not found". With stall set it reads requests
// and never replies; with dropAfterReply it closes each connection after one reply.
type fakeMemcached struct {
	ln             net.Listener
	stall          atomic.Bool
	dropAfterReply bool
	accepted       atomic.Int32
}

func startFake(t *testing.T) *fakeMemcached {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeMemcached{ln: ln}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			f.accepted.Add(1)
			go f.serve(c)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeMemcached) serve(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	for {
		var h [24]byte
		if _, err := io.ReadFull(r, h[:]); err != nil {
			return
		}
		if _, err := io.CopyN(io.Discard, r, int64(binary.BigEndian.Uint32(h[8:]))); err != nil {
			return
		}
		if f.stall.Load() {
			continue
		}
		resp := make([]byte, 24)
		resp[0], resp[1] = 0x81, h[1]
		binary.BigEndian.PutUint16(resp[6:], statusNotFound)
		c.Write(resp)
		if f.dropAfterReply {
			return
		}
	}
}

func fakeStore(t *testing.T, f *fakeMemcached) *Store {
	t.Helper()
	s, err := New([]string{f.ln.Addr().String()}, "ns", 100*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

func TestSlowReplyOnAPooledConnectionDoesNotMarkTheServerDown(t *testing.T) {
	f := startFake(t)
	s := fakeStore(t, f)
	ctx := t.Context()
	if _, found, err := s.Read(ctx, "k"); found || err != nil {
		t.Fatalf("first read = %v %v", found, err)
	}
	f.stall.Store(true)
	_, _, err := s.Read(ctx, "k")
	if !errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, ErrServerDown) {
		t.Errorf("a reply that never came is a timeout, got %v", err)
	}
	if s.ring.servers[0].down(time.Now()) {
		t.Fatal("one slow reply marked a healthy server down")
	}
	f.stall.Store(false)
	if _, _, err := s.Read(ctx, "k"); err != nil {
		t.Errorf("the next read: %v", err)
	}
}

func TestDialWithNoTimeLeftDoesNotMarkTheServerDown(t *testing.T) {
	f := startFake(t)
	s := fakeStore(t, f)
	srv := s.ring.servers[0]
	expired, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	if _, err := srv.dial(expired, context.Background(), time.Now()); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Errorf("dial = %v", err)
	}
	if srv.down(time.Now()) || f.accepted.Load() != 0 {
		t.Error("a dial past the deadline must neither run nor mark the server down")
	}
}

func TestDroppedPooledConnectionIsRetried(t *testing.T) {
	f := startFake(t)
	f.dropAfterReply = true
	s := fakeStore(t, f)
	ctx := t.Context()
	for i := range 3 {
		if _, _, err := s.Read(ctx, "k"); err != nil {
			t.Fatalf("read %d over a connection memcached dropped: %v", i, err)
		}
	}
	if n := f.accepted.Load(); n < 3 {
		t.Errorf("%d connections for 3 reads, each after a drop", n)
	}
}
