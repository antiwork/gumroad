package licenses

import (
	"math"
	"strconv"
	"strings"
	"time"
)

const (
	minutesInYear             = 525600
	minutesInQuarterYear      = 131400
	minutesInThreeQuarterYear = 394200
)

// timeAgoInWords is ActionView's time_ago_in_words under the en locale, without seconds.
func timeAgoInWords(from, now time.Time) string {
	from, to := from.UTC(), now.UTC()
	if from.After(to) {
		from, to = to, from
	}
	seconds := to.Sub(from).Seconds()
	minutes := int64(math.Round(seconds / 60))

	plural := func(count int64, one, other string) string {
		if count == 1 {
			return one
		}
		return strings.ReplaceAll(other, "%{count}", strconv.FormatInt(count, 10))
	}
	switch {
	case minutes == 0:
		return "less than a minute"
	case minutes == 1:
		return "1 minute"
	case minutes < 45:
		return plural(minutes, "1 minute", "%{count} minutes")
	case minutes < 90:
		return "about 1 hour"
	case minutes < 1440:
		return plural(int64(math.Round(float64(minutes)/60)), "about 1 hour", "about %{count} hours")
	case minutes < 2520:
		return "1 day"
	case minutes < 43200:
		return plural(int64(math.Round(float64(minutes)/1440)), "1 day", "%{count} days")
	case minutes < 86400:
		return plural(int64(math.Round(float64(minutes)/43200)), "about 1 month", "about %{count} months")
	case minutes < 525600:
		return plural(int64(math.Round(float64(minutes)/43200)), "1 month", "%{count} months")
	}

	fromYear := int64(from.Year())
	if from.Month() >= 3 {
		fromYear++
	}
	toYear := int64(to.Year())
	if to.Month() < 3 {
		toYear--
	}
	var leapYears int64
	if fromYear <= toYear {
		f := fromYear - 1
		leapYears = (toYear/4 - toYear/100 + toYear/400) - (f/4 - f/100 + f/400)
	}
	withOffset := minutes - leapYears*1440
	remainder, years := withOffset%minutesInYear, withOffset/minutesInYear
	switch {
	case remainder < minutesInQuarterYear:
		return plural(years, "about 1 year", "about %{count} years")
	case remainder < minutesInThreeQuarterYear:
		return plural(years, "over 1 year", "over %{count} years")
	}
	return plural(years+1, "almost 1 year", "almost %{count} years")
}
