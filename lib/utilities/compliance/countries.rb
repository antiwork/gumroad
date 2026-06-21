# frozen_string_literal: true

module Compliance
  module Countries
    ISO3166::Country.all.each do |country|
      self.const_set(country.alpha3, country)
    end

    def self.mapping
      ISO3166::Country.all.to_h { |country| [country.alpha2, country.common_name] }
    end

    def self.alpha2_by_name
      @alpha2_by_name ||= begin
        result = {}
        all = ISO3166::Country.all
        all.each do |country|
          [country.common_name, country.iso_short_name, country.iso_long_name].compact.each do |name|
            result[name.downcase] ||= country.alpha2
          end
        end
        all.each do |country|
          country.unofficial_names&.each { |name| result[name.downcase] ||= country.alpha2 }
        end
        all.each do |country|
          country.data["gumroad_historical_names"]&.each { |name| result[name.downcase] ||= country.alpha2 }
        end
        result.freeze
      end
    end

    def self.find_by_name(country_name)
      return if country_name.blank?
      ISO3166::Country.find_country_by_any_name(country_name)
    end

    def self.historical_names(country_name)
      country = find_by_name(country_name)
      return [] if country.nil?
      ([country.common_name] + (country.data["gumroad_historical_names"] || [])).uniq
    end
    # This list reflects countries under comprehensive OFAC sanctions.
    # Targeted SDN-list screening on individuals/entities is enforced
    # separately and is not based on country of residence.
    BLOCKED_COUNTRY_CODES = [
      CUB, # Cuba
      IRN, # Iran
      PRK, # North Korea
    ].map(&:alpha2).freeze
    private_constant :BLOCKED_COUNTRY_CODES

    def self.blocked?(alpha2)
      BLOCKED_COUNTRY_CODES.include?(alpha2)
    end
    # There are high levels of fraud originating in these countries.
    RISK_PHYSICAL_BLOCKED_COUNTRY_CODES = [
      ALB, # Albania,
      BGD, # Bangladesh,
      DZA, # Algeria,
      IDN, # Indonesia,
      LTU, # Lithuania,
      MAR, # Morocco,
      MMR, # Myanmar,
      PAN, # Panama,
      TUN, # Tunisia,
      VNM, # Vietnam
    ].map(&:alpha2).freeze
    private_constant :RISK_PHYSICAL_BLOCKED_COUNTRY_CODES

    def self.risk_physical_blocked?(alpha2)
      RISK_PHYSICAL_BLOCKED_COUNTRY_CODES.include?(alpha2)
    end

    # US outlying areas (territories) by ISO 3166-1 code. These are not sovereign countries, but ISO
    # assigns them codes and `for_select` lists them. How each is handled for seller compliance depends
    # on whether Stripe Connect accepts it — see `US_OUTLYING_AREAS_AS_STATES`.
    US_OUTLYING_AREA_ALPHA2 = %w[AS GU MP PR UM VI].freeze

    # The US outlying areas we model as a US state (`country: "US"`, `state: <code>`) rather than as
    # their own selectable country, because Stripe Connect onboards them under the US. Today that is
    # only Puerto Rico. These are filtered out of the seller country dropdown and rejected as a
    # compliance country, so a PR seller picks United States + state PR.
    #
    # The remaining outlying areas (Guam, US Virgin Islands, American Samoa, Northern Mariana Islands)
    # Stripe rejects outright, so they stay selectable as their own country and route to PayPal payouts
    # (`native_payouts_supported?` is false for them). #394 originally removed all six from the dropdown,
    # which left those four with no payout path at all — this restores it.
    US_OUTLYING_AREAS_AS_STATES = %w[PR].freeze

    def self.for_select
      ISO3166::Country.all.map do |country|
        name = blocked?(country.alpha2) ? "#{country.common_name} (not supported)" : country.common_name
        [country.alpha2, name]
      end.sort_by { |pair| pair.last }
    end

    # Same shape as `for_select`, but excludes the outlying areas we model as US states (PR), so a
    # seller cannot pick one as their country and end up in the issue #394 catch-22. The other outlying
    # areas stay listed because they are valid PayPal payout countries. Buyer-facing flows (checkout,
    # invoice, customer addresses) continue to use `for_select` because billing addresses to any
    # territory can be legitimate.
    def self.for_select_for_seller_compliance
      for_select.reject { |alpha2, _name| US_OUTLYING_AREAS_AS_STATES.include?(alpha2) }
    end

    GLOBE_SHOWING_AMERICAS_EMOJI = [127758].pack("U*")
    private_constant :GLOBE_SHOWING_AMERICAS_EMOJI

    def self.country_with_flag_by_name(country)
      country_code = Compliance::Countries.find_by_name(country)&.alpha2
      country_code.present? ?
        "#{country_code.codepoints.map { |char| 127397 + char }.pack('U*')} #{country}" :
        Compliance::Countries.elsewhere_with_flag
    end

    def self.elsewhere_with_flag
      "#{GLOBE_SHOWING_AMERICAS_EMOJI} Elsewhere"
    end

    JAPAN_PREFECTURE_KANA = {
      "北海道" => "ホッカイドウ",
      "青森県" => "アオモリケン",
      "岩手県" => "イワテケン",
      "宮城県" => "ミヤギケン",
      "秋田県" => "アキタケン",
      "山形県" => "ヤマガタケン",
      "福島県" => "フクシマケン",
      "茨城県" => "イバラキケン",
      "栃木県" => "トチギケン",
      "群馬県" => "グンマケン",
      "埼玉県" => "サイタマケン",
      "千葉県" => "チバケン",
      "東京都" => "トウキョウト",
      "神奈川県" => "カナガワケン",
      "新潟県" => "ニイガタケン",
      "富山県" => "トヤマケン",
      "石川県" => "イシカワケン",
      "福井県" => "フクイケン",
      "山梨県" => "ヤマナシケン",
      "長野県" => "ナガノケン",
      "岐阜県" => "ギフケン",
      "静岡県" => "シズオカケン",
      "愛知県" => "アイチケン",
      "三重県" => "ミエケン",
      "滋賀県" => "シガケン",
      "京都府" => "キョウトフ",
      "大阪府" => "オオサカフ",
      "兵庫県" => "ヒョウゴケン",
      "奈良県" => "ナラケン",
      "和歌山県" => "ワカヤマケン",
      "鳥取県" => "トットリケン",
      "島根県" => "シマネケン",
      "岡山県" => "オカヤマケン",
      "広島県" => "ヒロシマケン",
      "山口県" => "ヤマグチケン",
      "徳島県" => "トクシマケン",
      "香川県" => "カガワケン",
      "愛媛県" => "エヒメケン",
      "高知県" => "コウチケン",
      "福岡県" => "フクオカケン",
      "佐賀県" => "サガケン",
      "長崎県" => "ナガサキケン",
      "熊本県" => "クマモトケン",
      "大分県" => "オオイタケン",
      "宮崎県" => "ミヤザキケン",
      "鹿児島県" => "カゴシマケン",
      "沖縄県" => "オキナワケン",
    }.freeze
    private_constant :JAPAN_PREFECTURE_KANA

    def self.japan_prefecture_kana(kanji)
      JAPAN_PREFECTURE_KANA[kanji]
    end

    def self.japan_prefectures_for_select
      Compliance::Countries::JPN.subdivisions.values.map do |subdivision|
        kanji = subdivision.translations["ja"]
        { value: kanji, label: kanji, kana: JAPAN_PREFECTURE_KANA[kanji] }
      end
    end

    # `US_OUTLYING_AREAS_AS_STATES` (PR) is exposed in the US state dropdown because Stripe Connect
    # onboards those sellers under `country: "US"` with the territory as the `state`.
    def self.subdivisions_for_select(alpha2)
      case alpha2
      when Compliance::Countries::USA.alpha2
        Compliance::Countries::USA
          .subdivisions.values
          .filter_map do |subdivision|
            next unless ["state", "district"].include?(subdivision.type) ||
                        US_OUTLYING_AREAS_AS_STATES.include?(subdivision.code)
            [subdivision.code, subdivision.name]
          end
          .sort_by { |pair| pair.last }
      when Compliance::Countries::CAN.alpha2
        Compliance::Countries::CAN.subdivisions.values.map { |subdivision| [subdivision.code, subdivision.name] }.sort_by { |pair| pair.last }
      when Compliance::Countries::AUS.alpha2
        Compliance::Countries::AUS.subdivisions.values.map { |subdivision| [subdivision.code, subdivision.name] }.sort_by { |pair| pair.last }
      when Compliance::Countries::ARE.alpha2
        Compliance::Countries::ARE.subdivisions.values.map { |subdivision| [subdivision.code, subdivision.translations["en"]] }.sort_by { |pair| pair.last }
      when Compliance::Countries::MEX.alpha2
        Compliance::Countries::MEX.subdivisions.values.map { |subdivision| [subdivision.code, subdivision.name] }.sort_by { |pair| pair.last }
      when Compliance::Countries::IRL.alpha2
        Compliance::Countries::IRL.subdivisions.values
                                  .filter_map { |subdivision| [subdivision.code, subdivision.name] if subdivision.type == "county" }
                                  .sort_by { |pair| pair.last }
      when Compliance::Countries::BRA.alpha2
        Compliance::Countries::BRA.subdivisions.values.map { |subdivision| [subdivision.code, subdivision.name] }.sort_by { |pair| pair.last }
      else
        raise ArgumentError, "Country subdivisions not supported"
      end
    end

    # Returns the subdivision code given a country's alpha2 and a subdivision string.
    #
    # subdivision_str can be a code (like "CA") or name (like "California").
    # subdivision_str is case insensitive
    def self.find_subdivision_code(alpha2, subdivision_str)
      return nil if subdivision_str.nil?
      iso_country = ISO3166::Country[alpha2]
      return nil if iso_country.nil?
      return subdivision_str if iso_country.subdivisions.values.map(&:code).include?(subdivision_str)
      iso_country.subdivisions.values.find { |subdivision| [subdivision.name, subdivision.translations["en"]].map(&:downcase).include?(subdivision_str.downcase) }&.code
    end

    # As a Merchant of Record, Gumroad is required to collect sales tax in these US states.
    TAXABLE_US_STATE_CODES = %w(AR AZ CO CT DC GA HI IA IL IN KS KY LA MA MD MI MN NC ND NE NJ NV NY OH OK PA RI SD TN TX UT VT WA WI WV WY).freeze

    def self.taxable_state?(state_code)
      TAXABLE_US_STATE_CODES.include?(state_code)
    end

    VALID_INDIAN_STATES = %w[
      AP AR AS BR CG GA GJ HR HP JK JH KA
      KL MP MH MN ML MZ NL OR PB RJ SK TN
      TR UK UP WB
      AN CH DH DD DL LD PY
    ].to_set.freeze

    def self.valid_indian_state?(state_code)
      return false if state_code.blank? || state_code.match?(/^\d+$/)

      VALID_INDIAN_STATES.include?(state_code)
    end
    EU_VAT_APPLICABLE_COUNTRY_CODES = [
      AUT, # Austria,
      BEL, # Belgium,
      BGR, # Bulgaria,
      HRV, # Croatia,
      CYP, # Cyprus,
      CZE, # Czechia,
      DNK, # Denmark,
      EST, # Estonia,
      FIN, # Finland,
      FRA, # France,
      DEU, # Germany,
      GRC, # Greece,
      HUN, # Hungary,
      IRL, # Ireland,
      ITA, # Italy,
      LVA, # Latvia,
      LTU, # Lithuania,
      LUX, # Luxembourg,
      MLT, # Malta,
      NLD, # Netherlands,
      POL, # Poland,
      PRT, # Portugal,
      ROU, # Romania,
      SVK, # Slovakia,
      SVN, # Slovenia,
      ESP, # Spain,
      SWE, # Sweden,
      GBR, # United Kingdom
    ].map(&:alpha2).freeze

    NORWAY_VAT_APPLICABLE_COUNTRY_CODES = [
      NOR, # Norway
    ].map(&:alpha2).freeze

    GST_APPLICABLE_COUNTRY_CODES = [
      AUS, # Australia
      SGP, # Singapore
    ].map(&:alpha2).freeze

    OTHER_TAXABLE_COUNTRY_CODES = [
      CAN, # Canada
    ].map(&:alpha2).freeze

    COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS = [
      Compliance::Countries::ISL.alpha2, # Iceland
      Compliance::Countries::JPN.alpha2, # Japan
      Compliance::Countries::NZL.alpha2, # New Zealand
      Compliance::Countries::ZAF.alpha2, # South Africa
      Compliance::Countries::CHE.alpha2, # Switzerland
      Compliance::Countries::ARE.alpha2, # United Arab Emirates
      Compliance::Countries::IND.alpha2, # India
    ].freeze

    COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION = [
      Compliance::Countries::BLR.alpha2, # Belarus
      Compliance::Countries::CHL.alpha2, # Chile
      Compliance::Countries::COL.alpha2, # Colombia
      Compliance::Countries::CRI.alpha2, # Costa Rica
      Compliance::Countries::ECU.alpha2, # Ecuador
      Compliance::Countries::EGY.alpha2, # Egypt
      Compliance::Countries::GEO.alpha2, # Georgia
      Compliance::Countries::KAZ.alpha2, # Kazakhstan
      Compliance::Countries::MYS.alpha2, # Malaysia
      Compliance::Countries::MDA.alpha2, # Moldova
      Compliance::Countries::MAR.alpha2, # Morocco
      Compliance::Countries::RUS.alpha2, # Russia
      Compliance::Countries::SAU.alpha2, # Saudi Arabia
      Compliance::Countries::SRB.alpha2, # Serbia
      Compliance::Countries::KOR.alpha2, # South Korea
      Compliance::Countries::THA.alpha2, # Thailand
      Compliance::Countries::TUR.alpha2, # Turkey
      Compliance::Countries::UKR.alpha2, # Ukraine
      Compliance::Countries::UZB.alpha2, # Uzbekistan
      Compliance::Countries::VNM.alpha2 # Vietnam
    ].freeze

    COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITHOUT_TAX_ID_PRO_VALIDATION = [
      Compliance::Countries::BHR.alpha2, # Bahrain
      Compliance::Countries::KEN.alpha2, # Kenya
      Compliance::Countries::NGA.alpha2, # Nigeria
      Compliance::Countries::OMN.alpha2, # Oman
      Compliance::Countries::TZA.alpha2, # Tanzania
    ].freeze

    COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS = COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION + COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITHOUT_TAX_ID_PRO_VALIDATION
  end
end
