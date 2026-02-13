# frozen_string_literal: true

require "spec_helper"

describe Compliance do
  describe Countries do
    describe ".mapping" do
      it "returns a Hash of country codes to countries" do
        expect(Compliance::Countries.mapping).to eq(mapping_expected)
      end
    end

    describe ".find_by_name" do
      it "returns the country for a country whose name is the same for `countries` gem and `iso_country_codes` gem" do
        expect(Compliance::Countries.find_by_name("Mexico")).to eq(Compliance::Countries::MEX)
      end

      it "returns the country for a country whose name is different for `countries` gem and `iso_country_codes` gem" do
        expect(Compliance::Countries.find_by_name("South Korea")).to eq(Compliance::Countries::KOR)
        expect(Compliance::Countries.find_by_name("Korea, Republic of")).to eq(Compliance::Countries::KOR)
      end

      it "returns the country for a country whose name is different for `countries` gem and `maxmind/geoip2`" do
        expect(Compliance::Countries.find_by_name("Micronesia, Federated States of")).to eq(Compliance::Countries::FSM)
        expect(Compliance::Countries.find_by_name("Federated States of Micronesia")).to eq(Compliance::Countries::FSM)
      end

      it "returns nil for a nil country name" do
        expect(Compliance::Countries.find_by_name(nil)).to be_nil
      end

      it "returns nil for an empty country name" do
        expect(Compliance::Countries.find_by_name("")).to be_nil
      end
    end

    describe ".historical_names" do
      it "returns an empty array for a nil country name" do
        expect(Compliance::Countries.historical_names(nil)).to eq([])
      end

      it "returns the common name and gumroad historical names" do
        expected_historical_names = ["United States"]

        expect(Compliance::Countries.historical_names("United States")).to eq(expected_historical_names)
      end

      it "returns the common name and gumroad historical names for a country whose name is different for `countries` gem and `iso_country_codes` gem" do
        expected_historical_names = ["South Korea", "Korea, Republic of"]

        expect(Compliance::Countries.historical_names("South Korea")).to eq(expected_historical_names)
        expect(Compliance::Countries.historical_names("Korea, Republic of")).to eq(expected_historical_names)
      end

      it "returns the known names for a country whose name is different for `countries` gem and `maxmind/geoip2`" do
        expected_historical_names = ["Micronesia, Federated States of", "Federated States of Micronesia"]

        expect(Compliance::Countries.historical_names("Micronesia, Federated States of")).to eq(expected_historical_names)
        expect(Compliance::Countries.historical_names("Federated States of Micronesia")).to eq(expected_historical_names)
      end
    end

    describe ".blocked?" do
      it "returns false for United States" do
        expect(Compliance::Countries.blocked?("US")).to be false
      end

      it "returns true for Afghanistan" do
        expect(Compliance::Countries.blocked?("AF")).to be true
      end

      it "returns true for Cuba" do
        expect(Compliance::Countries.blocked?("CU")).to be true
      end

      it "returns true for Congo, the Democratic Republic of the" do
        expect(Compliance::Countries.blocked?("CD")).to be true
      end

      it "returns true for Côte d'Ivoire" do
        expect(Compliance::Countries.blocked?("CI")).to be true
      end

      it "returns true for Iraq" do
        expect(Compliance::Countries.blocked?("IQ")).to be true
      end

      it "returns true for Iran" do
        expect(Compliance::Countries.blocked?("IR")).to be true
      end

      it "returns true for Lebanon" do
        expect(Compliance::Countries.blocked?("LB")).to be true
      end

      it "returns true for Liberia" do
        expect(Compliance::Countries.blocked?("LR")).to be true
      end

      it "returns true for Libya" do
        expect(Compliance::Countries.blocked?("LY")).to be true
      end

      it "returns true for Myanmar" do
        expect(Compliance::Countries.blocked?("MM")).to be true
      end

      it "returns true for North Korea" do
        expect(Compliance::Countries.blocked?("KP")).to be true
      end

      it "returns true for Somalia" do
        expect(Compliance::Countries.blocked?("SO")).to be true
      end

      it "returns true for Sudan" do
        expect(Compliance::Countries.blocked?("SD")).to be true
      end

      it "returns true for Syrian Arab Republic" do
        expect(Compliance::Countries.blocked?("SY")).to be true
      end

      it "returns true for Yemen" do
        expect(Compliance::Countries.blocked?("YE")).to be true
      end

      it "returns true for Zimbabwe" do
        expect(Compliance::Countries.blocked?("ZW")).to be true
      end
    end

    describe ".for_select" do
      it "returns a sorted array of country names and codes" do
        expect(Compliance::Countries.for_select).to eq(for_select_expected)
      end
    end

    describe ".country_with_flag_by_name" do
      context "for a valid country name" do
        it "returns a country with its corresponding flag" do
          expect(Compliance::Countries.country_with_flag_by_name("United States")).to eq("🇺🇸 United States")
        end
      end

      context "for an invalid country name" do
        it "returns 'Elsewhere'" do
          expect(Compliance::Countries.country_with_flag_by_name("Mordor")).to eq("🌎 Elsewhere")
        end
      end

      context "when country name is nil" do
        it "returns 'Elsewhere'" do
          expect(Compliance::Countries.country_with_flag_by_name(nil)).to eq("🌎 Elsewhere")
        end
      end
    end

    describe ".elsewhere_with_flag" do
      it "returns 'Elsewhere' with globe emoji" do
        expect(Compliance::Countries.elsewhere_with_flag).to eq("🌎 Elsewhere")
      end
    end

    describe ".subdivisions_for_select" do
      it "returns expected subdivisions for united states" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::USA.alpha2)).to eq(united_states_subdivisions_for_select_expected)
      end

      it "returns expected subdivisions for canada" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2)).to eq(canada_subdivisions_for_select_expected)
      end

      it "returns expected subdivisions for australia" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::AUS.alpha2)).to eq(australia_subdivisions_for_select_expected)
      end

      it "returns expected subdivisions for united arab emirates" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::ARE.alpha2)).to eq(united_arab_emirates_subdivisions_for_select_expected)
      end

      it "returns expected subdivisions for mexico" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::MEX.alpha2)).to eq(mexico_subdivisions_for_select_expected)
      end

      it "returns expected subdivisions for ireland" do
        expect(Compliance::Countries.subdivisions_for_select(Compliance::Countries::IRL.alpha2)).to eq(ireland_subdivisions_for_select_expected)
      end

      it "raises an ArgumentError for a country we haven't added subdivision support for yet" do
        expect do
          Compliance::Countries.subdivisions_for_select(Compliance::Countries::QAT.alpha2)
        end.to raise_error(ArgumentError).with_message("Country subdivisions not supported")
      end
    end

    describe ".japan_prefectures_for_select" do
      it "returns all 47 Japan prefectures" do
        prefectures = Compliance::Countries.japan_prefectures_for_select
        expect(prefectures.length).to eq(47)
      end

      it "includes value, label, and kana for each prefecture" do
        prefectures = Compliance::Countries.japan_prefectures_for_select
        prefectures.each do |prefecture|
          expect(prefecture).to have_key(:value)
          expect(prefecture).to have_key(:label)
          expect(prefecture).to have_key(:kana)
          expect(prefecture[:value]).to eq(prefecture[:label])
        end
      end

      it "has kana mappings for all prefectures from ISO3166" do
        iso_prefectures = Compliance::Countries::JPN.subdivisions.values.map { |s| s.translations["ja"] }

        iso_prefectures.each do |prefecture_kanji|
          kana = Compliance::Countries.japan_prefecture_kana(prefecture_kanji)
          expect(kana).to be_present,
                          "Missing kana mapping for prefecture: #{prefecture_kanji}"
        end
      end
    end

    describe ".japan_prefecture_kana" do
      it "returns the kana reading for a valid prefecture" do
        expect(Compliance::Countries.japan_prefecture_kana("東京都")).to eq("トウキョウト")
        expect(Compliance::Countries.japan_prefecture_kana("北海道")).to eq("ホッカイドウ")
        expect(Compliance::Countries.japan_prefecture_kana("大阪府")).to eq("オオサカフ")
      end

      it "returns nil for an invalid prefecture" do
        expect(Compliance::Countries.japan_prefecture_kana("Invalid")).to be_nil
      end
    end

    describe ".find_subdivision_code" do
      it "returns the subdivision code for a valid subdivision code" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "CA")).to eq("CA")
      end

      it "returns the subdivision code for a valid subdivision name" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "California")).to eq("CA")
      end

      it "returns a subdivision code for a valid subdivision name with more than one word" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "North Dakota")).to eq("ND")
      end

      it "returns a subdivision code for a valid but mixed case subdivision name" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "caliFornia")).to eq("CA")
      end

      it "returns a subdivision code for a valid but mixed case subdivision name with more than one word" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "north dakota")).to eq("ND")
      end

      it "returns a subdivision code for mixed case District of Columbia" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, "distriCt of columbiA")).to eq("DC")
      end

      it "returns nil for an invalid subdivision name" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::USA.alpha2, nil)).to eq(nil)
      end

      it "returns nil for a nil country code" do
        expect(Compliance::Countries.find_subdivision_code(nil, "California")).to eq(nil)
      end

      it "returns nil for a mismatched country and subdivision combination" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::AUS.alpha2, "California")).to eq(nil)
      end

      it "returns a subdivision code for mixed case Newfoundland and Labrador" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::CAN.alpha2, "newfoundlanD and labraDor")).to eq("NL")
      end

      it "returns nil for a country without any subdivisions" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::PRI.alpha2, "Puerto Rico")).to eq(nil)
      end

      it "returns the expected subdivision code for a subdivision name given in the `countries` gem" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::ARE.alpha2, "Dubayy")).to eq("DU")
      end

      it "returns the expected subdivision code for a subdivision name's English translation in the `countries` gem" do
        expect(Compliance::Countries.find_subdivision_code(Compliance::Countries::ARE.alpha2, "Dubai")).to eq("DU")
      end
    end
  end

  def mapping_expected
    {
      "AD" => "Andorra",
      "AE" => "United Arab Emirates",
      "AF" => "Afghanistan",
      "AG" => "Antigua and Barbuda",
      "AI" => "Anguilla",
      "AL" => "Albania",
      "AM" => "Armenia",
      "AO" => "Angola",
      "AQ" => "Antarctica",
      "AR" => "Argentina",
      "AS" => "American Samoa",
      "AT" => "Austria",
      "AU" => "Australia",
      "AW" => "Aruba",
      "AX" => "Åland Islands",
      "AZ" => "Azerbaijan",
      "BA" => "Bosnia and Herzegovina",
      "BB" => "Barbados",
      "BD" => "Bangladesh",
      "BE" => "Belgium",
      "BF" => "Burkina Faso",
      "BG" => "Bulgaria",
      "BH" => "Bahrain",
      "BI" => "Burundi",
      "BJ" => "Benin",
      "BL" => "Saint Barthélemy",
      "BM" => "Bermuda",
      "BN" => "Brunei Darussalam",
      "BO" => "Bolivia",
      "BQ" => "Bonaire, Sint Eustatius and Saba",
      "BR" => "Brazil",
      "BS" => "Bahamas",
      "BT" => "Bhutan",
      "BV" => "Bouvet Island",
      "BW" => "Botswana",
      "BY" => "Belarus",
      "BZ" => "Belize",
      "CA" => "Canada",
      "CC" => "Cocos (Keeling) Islands",
      "CD" => "Congo, The Democratic Republic of the",
      "CF" => "Central African Republic",
      "CG" => "Congo",
      "CH" => "Switzerland",
      "CI" => "Côte d'Ivoire",
      "CK" => "Cook Islands",
      "CL" => "Chile",
      "CM" => "Cameroon",
      "CN" => "China",
      "CO" => "Colombia",
      "CR" => "Costa Rica",
      "CU" => "Cuba",
      "CV" => "Cabo Verde",
      "CW" => "Curaçao",
      "CX" => "Christmas Island",
      "CY" => "Cyprus",
      "CZ" => "Czechia",
      "DE" => "Germany",
      "DJ" => "Djibouti",
      "DK" => "Denmark",
      "DM" => "Dominica",
      "DO" => "Dominican Republic",
      "DZ" => "Algeria",
      "EC" => "Ecuador",
      "EE" => "Estonia",
      "EG" => "Egypt",
      "EH" => "Western Sahara",
      "ER" => "Eritrea",
      "ES" => "Spain",
      "ET" => "Ethiopia",
      "FI" => "Finland",
      "FJ" => "Fiji",
      "FK" => "Falkland Islands (Malvinas)",
      "FM" => "Micronesia, Federated States of",
      "FO" => "Faroe Islands",
      "FR" => "France",
      "GA" => "Gabon",
      "GB" => "United Kingdom",
      "GD" => "Grenada",
      "GE" => "Georgia",
      "GF" => "French Guiana",
      "GG" => "Guernsey",
      "GH" => "Ghana",
      "GI" => "Gibraltar",
      "GL" => "Greenland",
      "GM" => "Gambia",
      "GN" => "Guinea",
      "GP" => "Guadeloupe",
      "GQ" => "Equatorial Guinea",
      "GR" => "Greece",
      "GS" => "South Georgia and the South Sandwich Islands",
      "GT" => "Guatemala",
      "GU" => "Guam",
      "GW" => "Guinea-Bissau",
      "GY" => "Guyana",
      "HK" => "Hong Kong",
      "HM" => "Heard Island and McDonald Islands",
      "HN" => "Honduras",
      "HR" => "Croatia",
      "HT" => "Haiti",
      "HU" => "Hungary",
      "ID" => "Indonesia",
      "IE" => "Ireland",
      "IL" => "Israel",
      "IM" => "Isle of Man",
      "IN" => "India",
      "IO" => "British Indian Ocean Territory",
      "IQ" => "Iraq",
      "IR" => "Iran",
      "IS" => "Iceland",
      "IT" => "Italy",
      "JE" => "Jersey",
      "JM" => "Jamaica",
      "JO" => "Jordan",
      "JP" => "Japan",
      "KE" => "Kenya",
      "KG" => "Kyrgyzstan",
      "KH" => "Cambodia",
      "KI" => "Kiribati",
      "KM" => "Comoros",
      "KN" => "Saint Kitts and Nevis",
      "KP" => "North Korea",
      "KR" => "South Korea",
      "KW" => "Kuwait",
      "KY" => "Cayman Islands",
      "KZ" => "Kazakhstan",
      "LA" => "Lao People's Democratic Republic",
      "LB" => "Lebanon",
      "LC" => "Saint Lucia",
      "LI" => "Liechtenstein",
      "LK" => "Sri Lanka",
      "LR" => "Liberia",
      "LS" => "Lesotho",
      "LT" => "Lithuania",
      "LU" => "Luxembourg",
      "LV" => "Latvia",
      "LY" => "Libya",
      "MA" => "Morocco",
      "MC" => "Monaco",
      "MD" => "Moldova",
      "ME" => "Montenegro",
      "MF" => "Saint Martin (French part)",
      "MG" => "Madagascar",
      "MH" => "Marshall Islands",
      "MK" => "North Macedonia",
      "ML" => "Mali",
      "MM" => "Myanmar",
      "MN" => "Mongolia",
      "MO" => "Macao",
      "MP" => "Northern Mariana Islands",
      "MQ" => "Martinique",
      "MR" => "Mauritania",
      "MS" => "Montserrat",
      "MT" => "Malta",
      "MU" => "Mauritius",
      "MV" => "Maldives",
      "MW" => "Malawi",
      "MX" => "Mexico",
      "MY" => "Malaysia",
      "MZ" => "Mozambique",
      "NA" => "Namibia",
      "NC" => "New Caledonia",
      "NE" => "Niger",
      "NF" => "Norfolk Island",
      "NG" => "Nigeria",
      "NI" => "Nicaragua",
      "NL" => "Netherlands",
      "NO" => "Norway",
      "NP" => "Nepal",
      "NR" => "Nauru",
      "NU" => "Niue",
      "NZ" => "New Zealand",
      "OM" => "Oman",
      "PA" => "Panama",
      "PE" => "Peru",
      "PF" => "French Polynesia",
      "PG" => "Papua New Guinea",
      "PH" => "Philippines",
      "PK" => "Pakistan",
      "PL" => "Poland",
      "PM" => "Saint Pierre and Miquelon",
      "PN" => "Pitcairn",
      "PR" => "Puerto Rico",
      "PS" => "Palestine, State of",
      "PT" => "Portugal",
      "PW" => "Palau",
      "PY" => "Paraguay",
      "QA" => "Qatar",
      "RE" => "Réunion",
      "RO" => "Romania",
      "RS" => "Serbia",
      "RU" => "Russian Federation",
      "RW" => "Rwanda",
      "SA" => "Saudi Arabia",
      "SB" => "Solomon Islands",
      "SC" => "Seychelles",
      "SD" => "Sudan",
      "SE" => "Sweden",
      "SG" => "Singapore",
      "SH" => "Saint Helena, Ascension and Tristan da Cunha",
      "SI" => "Slovenia",
      "SJ" => "Svalbard and Jan Mayen",
      "SK" => "Slovakia",
      "SL" => "Sierra Leone",
      "SM" => "San Marino",
      "SN" => "Senegal",
      "SO" => "Somalia",
      "SR" => "Suriname",
      "SS" => "South Sudan",
      "ST" => "Sao Tome and Principe",
      "SV" => "El Salvador",
      "SX" => "Sint Maarten (Dutch part)",
      "SY" => "Syrian Arab Republic",
      "SZ" => "Eswatini",
      "TC" => "Turks and Caicos Islands",
      "TD" => "Chad",
      "TF" => "French Southern Territories",
      "TG" => "Togo",
      "TH" => "Thailand",
      "TJ" => "Tajikistan",
      "TK" => "Tokelau",
      "TL" => "Timor-Leste",
      "TM" => "Turkmenistan",
      "TN" => "Tunisia",
      "TO" => "Tonga",
      "TR" => "Türkiye",
      "TT" => "Trinidad and Tobago",
      "TV" => "Tuvalu",
      "TW" => "Taiwan",
      "TZ" => "Tanzania",
      "UA" => "Ukraine",
      "UG" => "Uganda",
      "UM" => "United States Minor Outlying Islands",
      "US" => "United States",
      "UY" => "Uruguay",
      "UZ" => "Uzbekistan",
      "VA" => "Holy See (Vatican City State)",
      "VC" => "Saint Vincent and the Grenadines",
      "VE" => "Venezuela",
      "VG" => "Virgin Islands, British",
      "VI" => "Virgin Islands, U.S.",
      "VN" => "Vietnam",
      "VU" => "Vanuatu",
      "WF" => "Wallis and Futuna",
      "WS" => "Samoa",
      "XK" => "Kosovo",
      "YE" => "Yemen",
      "YT" => "Mayotte",
      "ZA" => "South Africa",
      "ZM" => "Zambia",
      "ZW" => "Zimbabwe"
    }
  end

  def for_select_expected
    [
      ["AF", "Afghanistan (not supported)"],
      ["AL", "Albania"],
      ["DZ", "Algeria"],
      ["AS", "American Samoa"],
      ["AD", "Andorra"],
      ["AO", "Angola"],
      ["AI", "Anguilla"],
      ["AQ", "Antarctica"],
      ["AG", "Antigua and Barbuda"],
      ["AR", "Argentina"],
      ["AM", "Armenia"],
      ["AW", "Aruba"],
      ["AU", "Australia"],
      ["AT", "Austria"],
      ["AZ", "Azerbaijan"],
      ["BS", "Bahamas"],
      ["BH", "Bahrain"],
      ["BD", "Bangladesh"],
      ["BB", "Barbados"],
      ["BY", "Belarus"],
      ["BE", "Belgium"],
      ["BZ", "Belize"],
      ["BJ", "Benin"],
      ["BM", "Bermuda"],
      ["BT", "Bhutan"],
      ["BO", "Bolivia"],
      ["BQ", "Bonaire, Sint Eustatius and Saba"],
      ["BA", "Bosnia and Herzegovina"],
      ["BW", "Botswana"],
      ["BV", "Bouvet Island"],
      ["BR", "Brazil"],
      ["IO", "British Indian Ocean Territory"],
      ["BN", "Brunei Darussalam"],
      ["BG", "Bulgaria"],
      ["BF", "Burkina Faso"],
      ["BI", "Burundi"],
      ["CV", "Cabo Verde"],
      ["KH", "Cambodia"],
      ["CM", "Cameroon"],
      ["CA", "Canada"],
      ["KY", "Cayman Islands"],
      ["CF", "Central African Republic"],
      ["TD", "Chad"],
      ["CL", "Chile"],
      ["CN", "China"],
      ["CX", "Christmas Island"],
      ["CC", "Cocos (Keeling) Islands"],
      ["CO", "Colombia"],
      ["KM", "Comoros"],
      ["CG", "Congo"],
      ["CD", "Congo, The Democratic Republic of the (not supported)"],
      ["CK", "Cook Islands"],
      ["CR", "Costa Rica"],
      ["HR", "Croatia"],
      ["CU", "Cuba (not supported)"],
      ["CW", "Curaçao"],
      ["CY", "Cyprus"],
      ["CZ", "Czechia"],
      ["CI", "Côte d'Ivoire (not supported)"],
      ["DK", "Denmark"],
      ["DJ", "Djibouti"],
      ["DM", "Dominica"],
      ["DO", "Dominican Republic"],
      ["EC", "Ecuador"],
      ["EG", "Egypt"],
      ["SV", "El Salvador"],
      ["GQ", "Equatorial Guinea"],
      ["ER", "Eritrea"],
      ["EE", "Estonia"],
      ["SZ", "Eswatini"],
      ["ET", "Ethiopia"],
      ["FK", "Falkland Islands (Malvinas)"],
      ["FO", "Faroe Islands"],
      ["FJ", "Fiji"],
      ["FI", "Finland"],
      ["FR", "France"],
      ["GF", "French Guiana"],
      ["PF", "French Polynesia"],
      ["TF", "French Southern Territories"],
      ["GA", "Gabon"],
      ["GM", "Gambia"],
      ["GE", "Georgia"],
      ["DE", "Germany"],
      ["GH", "Ghana"],
      ["GI", "Gibraltar"],
      ["GR", "Greece"],
      ["GL", "Greenland"],
      ["GD", "Grenada"],
      ["GP", "Guadeloupe"],
      ["GU", "Guam"],
      ["GT", "Guatemala"],
      ["GG", "Guernsey"],
      ["GN", "Guinea"],
      ["GW", "Guinea-Bissau"],
      ["GY", "Guyana"],
      ["HT", "Haiti"],
      ["HM", "Heard Island and McDonald Islands"],
      ["VA", "Holy See (Vatican City State)"],
      ["HN", "Honduras"],
      ["HK", "Hong Kong"],
      ["HU", "Hungary"],
      ["IS", "Iceland"],
      ["IN", "India"],
      ["ID", "Indonesia"],
      ["IR", "Iran (not supported)"],
      ["IQ", "Iraq (not supported)"],
      ["IE", "Ireland"],
      ["IM", "Isle of Man"],
      ["IL", "Israel"],
      ["IT", "Italy"],
      ["JM", "Jamaica"],
      ["JP", "Japan"],
      ["JE", "Jersey"],
      ["JO", "Jordan"],
      ["KZ", "Kazakhstan"],
      ["KE", "Kenya"],
      ["KI", "Kiribati"],
      ["XK", "Kosovo"],
      ["KW", "Kuwait"],
      ["KG", "Kyrgyzstan"],
      ["LA", "Lao People's Democratic Republic"],
      ["LV", "Latvia"],
      ["LB", "Lebanon (not supported)"],
      ["LS", "Lesotho"],
      ["LR", "Liberia (not supported)"],
      ["LY", "Libya (not supported)"],
      ["LI", "Liechtenstein"],
      ["LT", "Lithuania"],
      ["LU", "Luxembourg"],
      ["MO", "Macao"],
      ["MG", "Madagascar"],
      ["MW", "Malawi"],
      ["MY", "Malaysia"],
      ["MV", "Maldives"],
      ["ML", "Mali"],
      ["MT", "Malta"],
      ["MH", "Marshall Islands"],
      ["MQ", "Martinique"],
      ["MR", "Mauritania"],
      ["MU", "Mauritius"],
      ["YT", "Mayotte"],
      ["MX", "Mexico"],
      ["FM", "Micronesia, Federated States of"],
      ["MD", "Moldova"],
      ["MC", "Monaco"],
      ["MN", "Mongolia"],
      ["ME", "Montenegro"],
      ["MS", "Montserrat"],
      ["MA", "Morocco"],
      ["MZ", "Mozambique"],
      ["MM", "Myanmar (not supported)"],
      ["NA", "Namibia"],
      ["NR", "Nauru"],
      ["NP", "Nepal"],
      ["NL", "Netherlands"],
      ["NC", "New Caledonia"],
      ["NZ", "New Zealand"],
      ["NI", "Nicaragua"],
      ["NE", "Niger"],
      ["NG", "Nigeria"],
      ["NU", "Niue"],
      ["NF", "Norfolk Island"],
      ["KP", "North Korea (not supported)"],
      ["MK", "North Macedonia"],
      ["MP", "Northern Mariana Islands"],
      ["NO", "Norway"],
      ["OM", "Oman"],
      ["PK", "Pakistan"],
      ["PW", "Palau"],
      ["PS", "Palestine, State of"],
      ["PA", "Panama"],
      ["PG", "Papua New Guinea"],
      ["PY", "Paraguay"],
      ["PE", "Peru"],
      ["PH", "Philippines"],
      ["PN", "Pitcairn"],
      ["PL", "Poland"],
      ["PT", "Portugal"],
      ["PR", "Puerto Rico"],
      ["QA", "Qatar"],
      ["RO", "Romania"],
      ["RU", "Russian Federation"],
      ["RW", "Rwanda"],
      ["RE", "Réunion"],
      ["BL", "Saint Barthélemy"],
      ["SH", "Saint Helena, Ascension and Tristan da Cunha"],
      ["KN", "Saint Kitts and Nevis"],
      ["LC", "Saint Lucia"],
      ["MF", "Saint Martin (French part)"],
      ["PM", "Saint Pierre and Miquelon"],
      ["VC", "Saint Vincent and the Grenadines"],
      ["WS", "Samoa"],
      ["SM", "San Marino"],
      ["ST", "Sao Tome and Principe"],
      ["SA", "Saudi Arabia"],
      ["SN", "Senegal"],
      ["RS", "Serbia"],
      ["SC", "Seychelles"],
      ["SL", "Sierra Leone"],
      ["SG", "Singapore"],
      ["SX", "Sint Maarten (Dutch part)"],
      ["SK", "Slovakia"],
      ["SI", "Slovenia"],
      ["SB", "Solomon Islands"],
      ["SO", "Somalia (not supported)"],
      ["ZA", "South Africa"],
      ["GS", "South Georgia and the South Sandwich Islands"],
      ["KR", "South Korea"],
      ["SS", "South Sudan"],
      ["ES", "Spain"],
      ["LK", "Sri Lanka"],
      ["SD", "Sudan (not supported)"],
      ["SR", "Suriname"],
      ["SJ", "Svalbard and Jan Mayen"],
      ["SE", "Sweden"],
      ["CH", "Switzerland"],
      ["SY", "Syrian Arab Republic (not supported)"],
      ["TW", "Taiwan"],
      ["TJ", "Tajikistan"],
      ["TZ", "Tanzania"],
      ["TH", "Thailand"],
      ["TL", "Timor-Leste"],
      ["TG", "Togo"],
      ["TK", "Tokelau"],
      ["TO", "Tonga"],
      ["TT", "Trinidad and Tobago"],
      ["TN", "Tunisia"],
      ["TM", "Turkmenistan"],
      ["TC", "Turks and Caicos Islands"],
      ["TV", "Tuvalu"],
      ["TR", "Türkiye"],
      ["UG", "Uganda"],
      ["UA", "Ukraine"],
      ["AE", "United Arab Emirates"],
      ["GB", "United Kingdom"],
      ["US", "United States"],
      ["UM", "United States Minor Outlying Islands"],
      ["UY", "Uruguay"],
      ["UZ", "Uzbekistan"],
      ["VU", "Vanuatu"],
      ["VE", "Venezuela"],
      ["VN", "Vietnam"],
      ["VG", "Virgin Islands, British"],
      ["VI", "Virgin Islands, U.S."],
      ["WF", "Wallis and Futuna"],
      ["EH", "Western Sahara"],
      ["YE", "Yemen (not supported)"],
      ["ZM", "Zambia"],
      ["ZW", "Zimbabwe (not supported)"],
      ["AX", "Åland Islands"]
    ]
  end

  def united_states_subdivisions_for_select_expected
    [
      ["AL", "Alabama"],
      ["AK", "Alaska"],
      ["AZ", "Arizona"],
      ["AR", "Arkansas"],
      ["CA", "California"],
      ["CO", "Colorado"],
      ["CT", "Connecticut"],
      ["DE", "Delaware"],
      ["DC", "District of Columbia"],
      ["FL", "Florida"],
      ["GA", "Georgia"],
      ["HI", "Hawaii"],
      ["ID", "Idaho"],
      ["IL", "Illinois"],
      ["IN", "Indiana"],
      ["IA", "Iowa"],
      ["KS", "Kansas"],
      ["KY", "Kentucky"],
      ["LA", "Louisiana"],
      ["ME", "Maine"],
      ["MD", "Maryland"],
      ["MA", "Massachusetts"],
      ["MI", "Michigan"],
      ["MN", "Minnesota"],
      ["MS", "Mississippi"],
      ["MO", "Missouri"],
      ["MT", "Montana"],
      ["NE", "Nebraska"],
      ["NV", "Nevada"],
      ["NH", "New Hampshire"],
      ["NJ", "New Jersey"],
      ["NM", "New Mexico"],
      ["NY", "New York"],
      ["NC", "North Carolina"],
      ["ND", "North Dakota"],
      ["OH", "Ohio"],
      ["OK", "Oklahoma"],
      ["OR", "Oregon"],
      ["PA", "Pennsylvania"],
      ["RI", "Rhode Island"],
      ["SC", "South Carolina"],
      ["SD", "South Dakota"],
      ["TN", "Tennessee"],
      ["TX", "Texas"],
      ["UT", "Utah"],
      ["VT", "Vermont"],
      ["VA", "Virginia"],
      ["WA", "Washington"],
      ["WV", "West Virginia"],
      ["WI", "Wisconsin"],
      ["WY", "Wyoming"]
    ]
  end

  def canada_subdivisions_for_select_expected
    [
      ["AB", "Alberta"],
      ["BC", "British Columbia"],
      ["MB", "Manitoba"],
      ["NB", "New Brunswick"],
      ["NL", "Newfoundland and Labrador"],
      ["NT", "Northwest Territories"],
      ["NS", "Nova Scotia"],
      ["NU", "Nunavut"],
      ["ON", "Ontario"],
      ["PE", "Prince Edward Island"],
      ["QC", "Quebec"],
      ["SK", "Saskatchewan"],
      ["YT", "Yukon"]
    ]
  end

  def australia_subdivisions_for_select_expected
    [
      ["ACT", "Australian Capital Territory"],
      ["NSW", "New South Wales"],
      ["NT", "Northern Territory"],
      ["QLD", "Queensland"],
      ["SA", "South Australia"],
      ["TAS", "Tasmania"],
      ["VIC", "Victoria"],
      ["WA", "Western Australia"]
    ]
  end

  def united_arab_emirates_subdivisions_for_select_expected
    [
      ["AZ", "Abu Dhabi"],
      ["AJ", "Ajman"],
      ["DU", "Dubai"],
      ["FU", "Fujairah"],
      ["RK", "Ras al-Khaimah"],
      ["SH", "Sharjah"],
      ["UQ", "Umm al-Quwain"]
    ]
  end

  def mexico_subdivisions_for_select_expected
    [
      ["AGU", "Aguascalientes"],
      ["BCN", "Baja California"],
      ["BCS", "Baja California Sur"],
      ["CAM", "Campeche"],
      ["CHP", "Chiapas"],
      ["CHH", "Chihuahua"],
      ["CMX", "Ciudad de México"],
      ["COA", "Coahuila"],
      ["COL", "Colima"],
      ["DUR", "Durango"],
      ["GUA", "Guanajuato"],
      ["GRO", "Guerrero"],
      ["HID", "Hidalgo"],
      ["JAL", "Jalisco"],
      ["MIC", "Michoacán"],
      ["MOR", "Morelos"],
      ["MEX", "México"],
      ["NAY", "Nayarit"],
      ["NLE", "Nuevo León"],
      ["OAX", "Oaxaca"],
      ["PUE", "Puebla"],
      ["QUE", "Querétaro"],
      ["ROO", "Quintana Roo"],
      ["SLP", "San Luis Potosí"],
      ["SIN", "Sinaloa"],
      ["SON", "Sonora"],
      ["TAB", "Tabasco"],
      ["TAM", "Tamaulipas"],
      ["TLA", "Tlaxcala"],
      ["VER", "Veracruz"],
      ["YUC", "Yucatán"],
      ["ZAC", "Zacatecas"]
    ]
  end

  def ireland_subdivisions_for_select_expected
    [
      ["CW", "Carlow"],
      ["CN", "Cavan"],
      ["CE", "Clare"],
      ["CO", "Cork"],
      ["DL", "Donegal"],
      ["D", "Dublin"],
      ["G", "Galway"],
      ["KY", "Kerry"],
      ["KE", "Kildare"],
      ["KK", "Kilkenny"],
      ["LS", "Laois"],
      ["LM", "Leitrim"],
      ["LK", "Limerick"],
      ["LD", "Longford"],
      ["LH", "Louth"],
      ["MO", "Mayo"],
      ["MH", "Meath"],
      ["MN", "Monaghan"],
      ["OY", "Offaly"],
      ["RN", "Roscommon"],
      ["SO", "Sligo"],
      ["TA", "Tipperary"],
      ["WD", "Waterford"],
      ["WH", "Westmeath"],
      ["WX", "Wexford"],
      ["WW", "Wicklow"]
    ]
  end

  def taxable_region_codes_expected
    [
      "US_AL",
      "US_AK",
      "US_AZ",
      "US_AR",
      "US_CA",
      "US_CO",
      "US_CT",
      "US_DE",
      "US_DC",
      "US_FL",
      "US_GA",
      "US_HI",
      "US_ID",
      "US_IL",
      "US_IN",
      "US_IA",
      "US_KS",
      "US_KY",
      "US_LA",
      "US_ME",
      "US_MD",
      "US_MA",
      "US_MI",
      "US_MN",
      "US_MS",
      "US_MO",
      "US_MT",
      "US_NE",
      "US_NV",
      "US_NH",
      "US_NJ",
      "US_NM",
      "US_NY",
      "US_NC",
      "US_ND",
      "US_OH",
      "US_OK",
      "US_OR",
      "US_PA",
      "US_PR",
      "US_RI",
      "US_SC",
      "US_SD",
      "US_TN",
      "US_TX",
      "US_UT",
      "US_VT",
      "US_VA",
      "US_WA",
      "US_WV",
      "US_WI",
      "US_WY",
    ]
  end
end
