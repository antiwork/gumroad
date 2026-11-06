package rails

import (
	_ "embed"
	"encoding/json"
	"strings"
)

// The keys of config/initializers/bots.rb's BOT_MAP, written by testdata/rails_fixtures.rb.
//
//go:embed bot_map.json
var botMapJSON []byte

var botUserAgents = func() map[string]bool {
	var agents []string
	if err := json.Unmarshal(botMapJSON, &agents); err != nil {
		panic(err)
	}
	set := make(map[string]bool, len(agents))
	for _, a := range agents {
		set[a] = true
	}
	return set
}()

// IsBot is ApplicationController#is_bot?.
func IsBot(req *Request) bool {
	ua := req.UserAgent()
	if ua == nil {
		return false
	}
	if botUserAgents[*ua] || Present(req.Param("user_agent_bot")) {
		return true
	}
	lower := strings.ToLower(*ua)
	for _, bot := range []string{"msnbot", "yahoo! slurp", "googlebot", "whatsapp"} {
		if strings.Contains(lower, bot) {
			return true
		}
	}
	return false
}
