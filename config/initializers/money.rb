# frozen_string_literal: true

Money.locale_backend = :i18n
Money.rounding_mode = BigDecimal::ROUND_HALF_UP
Money.default_currency = "USD"

# technically KRW does have subunits but they are not used anymore
# our currencies.yml assumes KRW to have 100 subunits and that's how we store them in the database
# the gem 'money' however treats KRW as a single unit currency by default
# https://github.com/RubyMoney/money/blob/master/config/currency_iso.json
# so we're performing this override here to have Money treat KRW amounts as 1/100th cents instead of units
# the alternative to this fix would be to update currencies.yml to list KRW as single-unit AND to update the database to divide all KRW prices by 100
Money::Currency.inherit :krw, subunit_to_unit: 100

# The gem 'money' treats HUF as a single unit currency by default
# so we're performing this override here to have Money treat HUF amounts as 1/100th cents instead of units
# because that is what ISO 4217 says and what PayPal expects.
# They're trying to do this migration in the gem too: https://github.com/RubyMoney/money/pull/742
Money::Currency.inherit :huf, subunit_to_unit: 100
