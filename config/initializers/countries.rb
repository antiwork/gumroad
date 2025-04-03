# frozen_string_literal: true

# Historically, we've gotten country names from a variety of sources:
# the `iso_country_codes` gem, `maxmind/geoip2`, and most recently the `countries` gem.
#
# With the modifications here, a call to `ISO3166::Country.find_country_by_any_name`
# will return the correct country from the `countries` gem,
# provided a country name from any of the above sources.
#
# Out of the box, all country names from `iso_country_codes` can be found in `countries`
#
# Added here are country names from `maxmind/geoip2` which can't be found in `countries`
ISO3166::Country["CG"].data["unofficial_names"] << "Congo Republic"
ISO3166::Country["FM"].data["unofficial_names"] << "Federated States of Micronesia"
ISO3166::Country["UM"].data["unofficial_names"] << "U.S. Outlying Islands"
ISO3166::Country["VC"].data["unofficial_names"] << "St Vincent and Grenadines"

# Similarly, there are times when we want to query by multiple country names,
# e.g., `WHERE purchases.country IN ()`
#
# For performance reasons, we don't want such queries to use all names known by the `countries` gem.
# So, we include historical names here.
ISO3166::Country["AX"].data["gumroad_historical_names"] = ["Åland"]
ISO3166::Country["BN"].data["gumroad_historical_names"] = ["Brunei"]
ISO3166::Country["BO"].data["gumroad_historical_names"] = ["Bolivia, Plurinational State of"]
ISO3166::Country["BQ"].data["gumroad_historical_names"] = ["Bonaire, Sint Eustatius, and Saba"]
ISO3166::Country["CG"].data["gumroad_historical_names"] = ["Congo Republic"]
ISO3166::Country["CZ"].data["gumroad_historical_names"] = ["Czech Republic"]
ISO3166::Country["FK"].data["gumroad_historical_names"] = ["Falkland Islands"]
ISO3166::Country["FM"].data["gumroad_historical_names"] = ["Federated States of Micronesia"]
ISO3166::Country["HM"].data["gumroad_historical_names"] = ["Heard and McDonald Islands"]
ISO3166::Country["KN"].data["gumroad_historical_names"] = ["St Kitts and Nevis"]
ISO3166::Country["KR"].data["gumroad_historical_names"] = ["Korea, Republic of"]
ISO3166::Country["LA"].data["gumroad_historical_names"] = ["Laos"]
ISO3166::Country["MD"].data["gumroad_historical_names"] = ["Moldova, Republic of"]
ISO3166::Country["MF"].data["gumroad_historical_names"] = ["Saint Martin"]
ISO3166::Country["MK"].data["gumroad_historical_names"] = ["Macedonia, the former Yugoslav Republic of"]
ISO3166::Country["PN"].data["gumroad_historical_names"] = ["Pitcairn Islands"]
ISO3166::Country["PS"].data["gumroad_historical_names"] = ["Palestine"]
ISO3166::Country["RU"].data["gumroad_historical_names"] = ["Russia"]
ISO3166::Country["SH"].data["gumroad_historical_names"] = ["Saint Helena"]
ISO3166::Country["ST"].data["gumroad_historical_names"] = ["São Tomé and Príncipe"]
ISO3166::Country["SX"].data["gumroad_historical_names"] = ["Sint Maarten"]
ISO3166::Country["SZ"].data["gumroad_historical_names"] = ["Swaziland"]
ISO3166::Country["TR"].data["gumroad_historical_names"] = ["Turkey"]
ISO3166::Country["TW"].data["gumroad_historical_names"] = ["Taiwan, Province of China"]
ISO3166::Country["TZ"].data["gumroad_historical_names"] = ["Tanzania, United Republic of"]
ISO3166::Country["UM"].data["gumroad_historical_names"] = ["U.S. Outlying Islands"]
ISO3166::Country["VA"].data["gumroad_historical_names"] = ["Vatican City"]
ISO3166::Country["VC"].data["gumroad_historical_names"] = ["St Vincent and Grenadines"]
ISO3166::Country["VE"].data["gumroad_historical_names"] = ["Venezuela, Bolivarian Republic of"]
ISO3166::Country["VG"].data["gumroad_historical_names"] = ["British Virgin Islands"]
ISO3166::Country["VI"].data["gumroad_historical_names"] = ["U.S. Virgin Islands"]

# We have to manually register Kosovo since it doesn't have an official ISO3166 code currently.
# XK & XXK are widely used for Kosovo currently. Although when Kosovo does get their own-
# ISO3166 code it will not be XK/XXK. https://en.wikipedia.org/wiki/XK_(user_assigned_code)
ISO3166::Data.register(
  alpha3: "XXK",
  alpha2: "XK",
  translations: {
    "en": "Kosovo"
  },
  continent: "Europe"
)
