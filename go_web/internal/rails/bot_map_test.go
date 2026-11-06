package rails

import (
	"encoding/json"
	"os"
	"regexp"
	"testing"
)

var botMapEntry = regexp.MustCompile(`(?m)^\s*".*" => ".*",?$`)

// bot_map.json is generated from BOT_MAP; this catches an entry added or removed in Rails
// without regenerating it.
func TestBotMapMatchesTheRailsInitializer(t *testing.T) {
	source, err := os.ReadFile("../../../config/initializers/bots.rb")
	if os.IsNotExist(err) {
		t.Skip("not running inside the Rails checkout")
	}
	if err != nil {
		t.Fatal(err)
	}
	var agents []string
	if err := json.Unmarshal(botMapJSON, &agents); err != nil {
		t.Fatal(err)
	}
	if want := len(botMapEntry.FindAll(source, -1)); len(agents) != want {
		t.Fatalf("bot_map.json has %d entries, BOT_MAP has %d; run internal/rails/testdata/rails_fixtures.rb", len(agents), want)
	}
}
