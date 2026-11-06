package rails

import "testing"

// Each want is what Rails' String#parameterize returned for its input on the production console.
func TestParameterize(t *testing.T) {
	for in, want := range map[string]string{
		"Café crème":      "cafe-creme",
		"naïve façade":    "naive-facade",
		"Größe":           "grosse",
		"日本語 list":        "list",
		"é":              "e",
		"Å":               "a",
		"Ærø":             "aero",
		"Hello__World--x": "hello__world-x",
		"-a-":             "a",
		"Ünïcødé ✨ wish":  "unicode-wish",
	} {
		if got := Parameterize(in); got != want {
			t.Errorf("Parameterize(%q) = %q, want %q", in, got, want)
		}
	}
}
