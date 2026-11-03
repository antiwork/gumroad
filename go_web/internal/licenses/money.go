package licenses

import (
	"fmt"
	"strconv"
	"strings"
)

// currencyFormat is what Money#format(no_cents_if_whole: true, symbol: true) reads for the
// currencies in config/currencies.json, under config/initializers/money.rb (i18n backend with
// Rails' en separators, KRW and HUF re-based to 100 subunits). The symbol goes in prefix or
// suffix, as the currency's "%u%n", "%u %n" or "%n %u" layout puts it.
type currencyFormat struct {
	subunits int64
	prefix   string
	suffix   string
}

func before(symbol string) currencyFormat { return currencyFormat{100, symbol, ""} }
func after(symbol string) currencyFormat  { return currencyFormat{100, "", " " + symbol} }

var currencyFormats = map[string]currencyFormat{
	"usd": before("$"), "gbp": before("£"), "eur": before("€"), "jpy": {1, "¥", ""}, "inr": before("₹"),
	"aud": before("$"), "cad": before("$"), "hkd": before("$"), "sgd": before("$"), "twd": before("$"),
	"nzd": before("$"), "brl": before("R$"), "zar": before("R"), "chf": before("CHF "), "ils": before("₪"),
	"php": before("₱"), "krw": before("₩"), "pln": after("zł"), "czk": after("Kč"), "sek": after("kr"),
	"nok": after("kr"), "dkk": after("kr."), "mxn": before("$"), "sar": before("ر.س"), "aed": after("د.إ"),
	"try": before("₺"), "cop": before("$"), "ron": after("Lei"), "thb": before("฿"), "myr": before("RM"),
	"vnd": {1, "", " ₫"}, "idr": before("Rp"),
}

// formatMoney is Money.new(cents, currency).format(no_cents_if_whole: true, symbol: true).
func formatMoney(cents int64, currency string) (string, error) {
	f, ok := currencyFormats[strings.ToLower(currency)]
	if !ok {
		return "", fmt.Errorf("unknown currency %q", currency)
	}
	sign := ""
	if cents < 0 {
		sign, cents = "-", -cents
	}
	number := sign + groupThousands(strconv.FormatInt(cents/f.subunits, 10))
	if fraction := cents % f.subunits; fraction != 0 {
		number += fmt.Sprintf(".%02d", fraction)
	}
	return f.prefix + number + f.suffix, nil
}

func groupThousands(digits string) string {
	var b strings.Builder
	for i, c := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}
