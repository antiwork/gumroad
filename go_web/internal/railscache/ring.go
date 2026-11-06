package railscache

import (
	"crypto/sha1"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"math"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Dalli::Ring::POINTS_PER_SERVER.
const pointsPerServer = 160

// Ring#server_from_continuum's retry count.
const failoverTries = 20

type point struct {
	value  uint32
	server int
}

type ring struct {
	servers []*server
	points  []point // nil with one server: Dalli then always takes the first
}

// serverConfig matches Dalli::Protocol::ServerConfigParser::SERVER_CONFIG_REGEXP.
var serverConfig = regexp.MustCompile(`\A(\[([0-9A-Fa-f:]+)\]|[^:]+)(?::(\d+))?(?::(\d+))?\z`)

// parseServers is ServersArgNormalizer.normalize_servers then ServerConfigParser.parse.
func parseServers(args []string) ([]*server, error) {
	var servers []*server
	for _, arg := range args {
		for _, s := range strings.Split(arg, ",") {
			if s == "" {
				continue
			}
			if strings.HasPrefix(s, "memcached://") {
				return nil, fmt.Errorf("railscache: memcached:// servers (SASL) are not supported: %q", s)
			}
			m := serverConfig.FindStringSubmatch(s)
			if m == nil || m[1] == "[]" {
				return nil, fmt.Errorf("railscache: could not parse hostname %s", s)
			}
			host := m[1]
			if m[2] != "" {
				host = m[2]
			}
			srv := &server{weight: 1}
			if strings.HasPrefix(host, "/") {
				if m[4] != "" {
					return nil, fmt.Errorf("railscache: could not parse hostname %s", s)
				}
				srv.name, srv.network, srv.addr = host, "unix", host
				if m[3] != "" {
					w, err := rubyInteger(m[3])
					if err != nil {
						return nil, err
					}
					srv.weight = w
				}
			} else {
				port := 11211
				if m[3] != "" {
					p, err := rubyInteger(m[3])
					if err != nil {
						return nil, err
					}
					port = p
				}
				if m[4] != "" {
					w, err := rubyInteger(m[4])
					if err != nil {
						return nil, err
					}
					srv.weight = w
				}
				// ConnectionManager#name is "#{hostname}:#{port}", unbracketed even for IPv6.
				srv.name = host + ":" + strconv.Itoa(port)
				srv.network = "tcp"
				srv.addr = net.JoinHostPort(host, strconv.Itoa(port))
			}
			srv.init()
			servers = append(servers, srv)
		}
	}
	if len(servers) == 0 {
		return nil, fmt.Errorf("railscache: no servers")
	}
	return servers, nil
}

// rubyInteger is Kernel#Integer on a run of digits: a leading 0 makes it octal.
func rubyInteger(s string) (int, error) {
	base := 10
	if len(s) > 1 && s[0] == '0' {
		base = 8
	}
	n, err := strconv.ParseInt(s, base, 32)
	if err != nil {
		return 0, fmt.Errorf("railscache: invalid value for Integer(): %q", s)
	}
	return int(n), nil
}

func newRing(servers []*server) (*ring, error) {
	r := &ring{servers: servers}
	if len(servers) < 2 {
		return r, nil
	}
	total := 0
	for _, s := range servers {
		total += s.weight
	}
	if total <= 0 {
		return nil, fmt.Errorf("railscache: server weights sum to %d", total)
	}
	for i, s := range servers {
		// Ring#entry_count_for
		n := int(math.Floor(float64(len(servers)*pointsPerServer*s.weight) / float64(total)))
		for idx := range n {
			sum := sha1.Sum([]byte(s.name + ":" + strconv.Itoa(idx)))
			r.points = append(r.points, point{binary.BigEndian.Uint32(sum[:4]), i})
		}
	}
	sort.SliceStable(r.points, func(i, j int) bool { return r.points[i].value < r.points[j].value })
	// sort_by isn't stable, so Ruby's order between two servers' equal points is arbitrary.
	for i := 1; i < len(r.points); i++ {
		if a, b := r.points[i-1], r.points[i]; a.value == b.value && a.server != b.server {
			return nil, fmt.Errorf("railscache: %s and %s share continuum point %d",
				servers[a.server].name, servers[b.server].name, a.value)
		}
	}
	return r, nil
}

// candidate is the server Ring#server_from_continuum tries on attempt try (0 is the
// primary; attempt n+1 rehashes "#{n}#{key}").
func (r *ring) candidate(key string, try int) *server {
	if r.points == nil {
		return r.servers[0]
	}
	h := crc32.ChecksumIEEE([]byte(key))
	if try > 0 {
		h = crc32.ChecksumIEEE([]byte(strconv.Itoa(try-1) + key))
	}
	// Ring#server_for_hash_key: the last point <= h, wrapping to the last point.
	i := sort.Search(len(r.points), func(i int) bool { return r.points[i].value > h })
	if i == 0 {
		i = len(r.points)
	}
	return r.servers[r.points[i-1].server]
}
