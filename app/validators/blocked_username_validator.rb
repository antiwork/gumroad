# frozen_string_literal: true

# Rejects usernames that spam accounts use for storefronts: gambling brands, and well-known company
# names claimed by someone who is not signing up with that company's email address.
#
# A brand username is allowed when the account email is on the brand's own domain. Anyone else who
# has a real claim to the name emails support, and we create the account by hand.
class BlockedUsernameValidator < ActiveModel::EachValidator
  BLOCKED_MESSAGE = "isn't available. If you represent this company, email support@gumroad.com and we'll set up your account."

  # Usernames are lowercase letters and digits only, so these are matched as substrings.
  # Plain "casino" and "poker" are left out on purpose: casino strategy and poker coaching sellers
  # are allowed, so only the online-gambling forms are matched.
  GAMBLING_PATTERN = Regexp.union(
    /onlinecasino/, /casinoonline/, /casino\d/, /togel/, /sbobet/, /nhacai/, /cacuoc/, /sunwin/, /hitclub/,
    /789club/, /slot(gacor|online|\d{2,})/, /gacor/, /judi(online|slot|bola)/, /bandarq/,
    /poker(online|qq|\d{2,})/, /bet\d{2,}/, /\d{2,}bet/, /88(bet|win|club|vip|tv|com|net)/,
    /\A(go|sv|sn|m|w|fb|bk|ae|dt|qs|sc|wi|du|v9|hi|ok)(8|88|99|168|188|388|789|888|999)([a-z]{0,6})?\z/,
    /\A(8x|188|12|78|23|28|122|555|68|iwin|win)(bet|win|club)\z/, /jeetwin/, /phlwin/, /kubet/, /\Anohu\d*\z/,
  ).freeze

  # brand username => the email domains that may use it.
  BRANDS = {
    "apple" => %w[apple.com], "google" => %w[google.com], "microsoft" => %w[microsoft.com],
    "amazon" => %w[amazon.com], "facebook" => %w[facebook.com meta.com],
    "instagram" => %w[instagram.com meta.com], "whatsapp" => %w[whatsapp.com meta.com],
    "netflix" => %w[netflix.com], "tesla" => %w[tesla.com], "walmart" => %w[walmart.com],
    "paypal" => %w[paypal.com], "stripe" => %w[stripe.com], "visa" => %w[visa.com],
    "mastercard" => %w[mastercard.com], "americanexpress" => %w[aexp.com americanexpress.com],
    "chase" => %w[chase.com jpmorgan.com jpmchase.com], "jpmorgan" => %w[jpmorgan.com jpmchase.com],
    "wellsfargo" => %w[wellsfargo.com], "bankofamerica" => %w[bankofamerica.com bofa.com],
    "citibank" => %w[citi.com citibank.com], "hsbc" => %w[hsbc.com], "barclays" => %w[barclays.com],
    "lloyds" => %w[lloydsbanking.com lloydsbank.co.uk], "natwest" => %w[natwest.com],
    "santander" => %w[santander.com santander.co.uk], "binance" => %w[binance.com], "coinbase" => %w[coinbase.com],
    "bt" => %w[bt.com bt.co.uk], "btinternet" => %w[bt.com bt.co.uk], "btbroadband" => %w[bt.com bt.co.uk],
    "ee" => %w[ee.co.uk bt.com], "eebroadband" => %w[ee.co.uk bt.com],
    "vodafone" => %w[vodafone.com vodafone.co.uk],
    # Virgin Media issues virginmedia.com addresses to its residential customers, so that domain
    # proves nothing about representing the company: no automatic exemption for anyone.
    "virginmedia" => [],
    "talktalk" => %w[talktalk.co.uk talktalkgroup.com], "att" => %w[att.com], "verizon" => %w[verizon.com],
    "tmobile" => %w[t-mobile.com], "comcast" => %w[comcast.com], "xfinity" => %w[comcast.com xfinity.com],

    "dhl" => %w[dhl.com], "fedex" => %w[fedex.com], "ups" => %w[ups.com], "usps" => %w[usps.gov usps.com],
    "royalmail" => %w[royalmail.com], "dpd" => %w[dpd.com dpd.co.uk],
    "nike" => %w[nike.com], "adidas" => %w[adidas.com], "puma" => %w[puma.com], "gucci" => %w[gucci.com],
    "louisvuitton" => %w[louisvuitton.com lvmh.com], "chanel" => %w[chanel.com], "rolex" => %w[rolex.com],
    "cocacola" => %w[coca-cola.com coke.com], "pepsi" => %w[pepsico.com pepsi.com],
    "mcdonalds" => %w[mcdonalds.com us.mcd.com], "starbucks" => %w[starbucks.com],
    "disney" => %w[disney.com thewaltdisneycompany.com], "samsung" => %w[samsung.com], "sony" => %w[sony.com],
    "intel" => %w[intel.com], "nvidia" => %w[nvidia.com], "oracle" => %w[oracle.com], "ibm" => %w[ibm.com],
    "adobe" => %w[adobe.com], "salesforce" => %w[salesforce.com], "spotify" => %w[spotify.com],
    "uber" => %w[uber.com], "airbnb" => %w[airbnb.com], "dropbox" => %w[dropbox.com], "shopify" => %w[shopify.com],
    "ebay" => %w[ebay.com], "alibaba" => %w[alibaba-inc.com alibaba.com], "tiktok" => %w[tiktok.com bytedance.com],
    "twitter" => %w[x.com twitter.com], "linkedin" => %w[linkedin.com microsoft.com],
    "youtube" => %w[youtube.com google.com], "openai" => %w[openai.com], "anthropic" => %w[anthropic.com],
    "toyota" => %w[toyota.com], "bmw" => %w[bmw.com], "mercedes" => %w[mercedes-benz.com],
    "boeing" => %w[boeing.com], "pfizer" => %w[pfizer.com], "costco" => %w[costco.com],
    "homedepot" => %w[homedepot.com], "ikea" => %w[ikea.com], "unilever" => %w[unilever.com],
    "nestle" => %w[nestle.com], "bp" => %w[bp.com], "exxonmobil" => %w[exxonmobil.com],
    "gumroad" => %w[gumroad.com], "gumroadsupport" => %w[gumroad.com],
  }.freeze

  # Words spammers add to a brand to make it look official ("nikeofficial", "paypalsupport", "nike123").
  BRAND_AFFIXES = %w[official support help care store shop inc corp hq usa uk us global team login secure service].freeze

  class << self
    def blocked?(username, email: nil)
      name = username.to_s.downcase
      return false if name.blank?
      return true if name.match?(GAMBLING_PATTERN)

      domains = brand_domains(name)
      return false if domains.nil?

      !email_on_domains?(email, domains)
    end

    # The brand exemption needs an address the account has PROVED it owns. Signup stores whatever
    # string was typed, so an unconfirmed brand-domain address must not grant the brand name.
    def blocked_for?(username, record)
      blocked?(username, email: proven_email(record))
    end

    private
      # An unconfirmed address is a claim, not proof, and neither is a pending change: Devise moves a
      # replacement address into `unconfirmed_email` only AFTER validation, so one request that sets
      # `email` and `username` together would otherwise be judged on an address the account has not
      # proved. The persisted address is the one that was confirmed, so it is what counts.
      def proven_email(record)
        return nil unless record.try(:confirmed?)
        return record.try(:email_in_database) if record.try(:persisted?) && record.try(:will_save_change_to_email?)

        record.try(:email)
      end

      # Returns the allowed email domains when the username is a brand name (or a brand with an
      # affix), nil when it is not a brand.
      def brand_domains(name)
        BRANDS.each do |brand, domains|
          return domains if name == brand
          next unless name.start_with?(brand) || name.end_with?(brand)

          rest = name.delete_prefix(brand).then { |stripped| stripped == name ? name.delete_suffix(brand) : stripped }
          rest = rest.delete_prefix("the").delete_prefix("official")
          return domains if rest.empty? || BRAND_AFFIXES.include?(rest) || (brand.length >= 3 && rest.match?(/\A\d{1,4}\z/))
        end
        nil
      end

      def email_on_domains?(email, domains)
        domain = email.to_s.downcase.split("@", 2)[1]
        return false if domain.blank?

        domains.any? { |allowed| domain == allowed || domain.end_with?(".#{allowed}") }
      end
  end

  def validate_each(record, attribute, value)
    return unless self.class.blocked_for?(value, record)

    record.errors.add(attribute, options[:message] || BLOCKED_MESSAGE)
  end
end
