package products

import "strings"

// moneyCurrencies are the money gem's registered currency codes (currency_iso.json,
// currency_non_iso.json and currency_backwards_compatible.json in money 6.19.0), which
// MoneyFormatter's find_currency knows; it soft-fails on any other.
var moneyCurrencies = func() map[string]bool {
	m := map[string]bool{}
	for _, code := range strings.Fields("aed afn all amd ang aoa ars aud awg azn bam bbd bch bdt bgn bhd bif bmd bnd bob brl bsd btc btn bwp byn byr bzd cad cdf chf clf clp cnh cny cop crc cuc cup cve czk djf dkk dop dzd eek egp ern etb eur fjd fkp gbp gbx gel ggp ghc ghs gip gmd gnf gtq gyd hkd hnl hrk htg huf idr ils imp inr iqd irr isk jep jmd jod jpy kes kgs khr kmf kpw krw kwd kyd kzt lak lbp lkr lrd lsl ltl lvl lyd mad mdl mga mkd mmk mnt mop mro mru mtl mur mvr mwk mxn myr mzn nad ngn nio nok npr nzd omr pab pen pgk php pkr pln pyg qar ron rsd rub rwf sar sbd scr sdg sek sgd shp skk sle sll sos srd ssp std stn svc syp szl thb tjs tmm tmt tnd top try ttd twd tzs uah ugx usd usdc uyu uzs vef ves vnd vuv wst xaf xag xau xba xbb xbc xbd xcd xdr xfu xof xpd xpf xpt xts yen yer zar zmk zmw zwd zwl zwn zwr") {
		m[code] = true
	}
	return m
}()
