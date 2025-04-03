# frozen_string_literal: true

ZipTaxRate.find_or_create_by(country: "BH").update(combined_rate: 0.10) # Bahrain
ZipTaxRate.find_or_create_by(country: "BY").update(combined_rate: 0.20) # Belarus
ZipTaxRate.find_or_create_by(country: "CL").update(combined_rate: 0.19) # Chile
ZipTaxRate.find_or_create_by(country: "CO").update(combined_rate: 0.19) # Colombia
ZipTaxRate.find_or_create_by(country: "CR").update(combined_rate: 0.13) # Costa Rica
ZipTaxRate.find_or_create_by(country: "EC").update(combined_rate: 0.12) # Ecuador
ZipTaxRate.find_or_create_by(country: "EG").update(combined_rate: 0.14) # Egypt
ZipTaxRate.find_or_create_by(country: "GE").update(combined_rate: 0.18) # Georgia
ZipTaxRate.find_or_create_by(country: "KE").update(combined_rate: 0.16) # Kenya
ZipTaxRate.find_or_create_by(country: "KR").update(combined_rate: 0.10) # South Korea
ZipTaxRate.find_or_create_by(country: "KZ").update(combined_rate: 0.12) # Kazakhstan
ZipTaxRate.find_or_create_by(country: "MA").update(combined_rate: 0.20) # Morocco
ZipTaxRate.find_or_create_by(country: "MD").update(combined_rate: 0.20) # Moldova
ZipTaxRate.find_or_create_by(country: "MX").update(combined_rate: 0.16) # Mexico
ZipTaxRate.find_or_create_by(country: "MX", flags: 2).update(combined_rate: 0.00) # Mexico
ZipTaxRate.find_or_create_by(country: "MY").update(combined_rate: 0.06) # Malaysia
ZipTaxRate.find_or_create_by(country: "NG").update(combined_rate: 0.075) # Nigeria
ZipTaxRate.find_or_create_by(country: "OM").update(combined_rate: 0.05) # Oman
ZipTaxRate.find_or_create_by(country: "RS").update(combined_rate: 0.20) # Serbia
ZipTaxRate.find_or_create_by(country: "RU").update(combined_rate: 0.20) # Russia
ZipTaxRate.find_or_create_by(country: "SA").update(combined_rate: 0.15) # Saudi Arabia
ZipTaxRate.find_or_create_by(country: "TH").update(combined_rate: 0.07) # Thailand
ZipTaxRate.find_or_create_by(country: "TR").update(combined_rate: 0.20) # Turkey
ZipTaxRate.find_or_create_by(country: "TZ").update(combined_rate: 0.18) # Tanzania
ZipTaxRate.find_or_create_by(country: "UA").update(combined_rate: 0.20) # Ukraine
ZipTaxRate.find_or_create_by(country: "UZ").update(combined_rate: 0.15) # Uzbekistan
ZipTaxRate.find_or_create_by(country: "VN").update(combined_rate: 0.10) # Vietnam
