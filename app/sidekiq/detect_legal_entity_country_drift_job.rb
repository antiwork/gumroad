# frozen_string_literal: true

# Records when a seller's derived legal-entity country stops agreeing with the
# country their Stripe account was actually created in.
#
# `UserComplianceInfo#legal_entity_country_code` is derived on every read as
# `(business_country_code if is_business?) || country_code`. Nothing caches or
# re-validates it, so a seller who opened an account as a US business and later
# flips `is_business` to false silently starts deriving their cross-border
# personal country instead — while the Stripe account keeps `country: "US"`
# forever. Stripe then rejects the whole compliance payload (recipient ToS,
# then company address country), which is the cohort in gumroad-private#1512.
#
# The check deliberately does not live in `legal_entity_country_code` itself:
# that reader has 48 call sites, most of them on payout and compliance paths,
# and a derivation that raises or writes state at read time is how a country
# check ends up throwing inside a payout run. Detect at the point the input
# changes instead.
#
# A drift cannot be self-healed. Stripe will not change an existing account's
# country, so clearing it means opening a new account — a support decision,
# not something to automate. This job records and stops.
class DetectLegalEntityCountryDriftJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  AUTHOR_NAME = "legal-entity-country-drift"
  # A seller can edit compliance details repeatedly while the mismatch stands.
  # Re-noting the same pair every time buries the first, real event.
  DEDUP_WINDOW = 30.days

  def perform(user_compliance_info_id)
    compliance_info = UserComplianceInfo.find_by(id: user_compliance_info_id)
    return if compliance_info.nil?

    user = compliance_info.user
    return if user.nil?

    derived_country = compliance_info.legal_entity_country_code
    return if derived_country.blank?

    merchant_account = user.stripe_account
    return if merchant_account.nil?
    # Stripe Connect accounts are the seller's own; we do not push a legal
    # entity onto them, so a country disagreement has no consequence there.
    return unless merchant_account.is_a_gumroad_managed_stripe_account?

    account_country = merchant_account.country
    return if account_country.blank?
    return if account_country == derived_country

    content = "Legal-entity country #{derived_country} does not match the Stripe " \
              "account country #{account_country} (#{merchant_account.charge_processor_merchant_id}). " \
              "Compliance resync to Stripe will fail for this seller until the account is " \
              "recreated in the correct country; Stripe cannot change an existing account's country."

    return if user.comments
                  .with_type_note
                  .where(author_name: AUTHOR_NAME, content:)
                  .where("created_at > ?", DEDUP_WINDOW.ago)
                  .exists?

    user.comments.create!(
      author_name: AUTHOR_NAME,
      comment_type: Comment::COMMENT_TYPE_NOTE,
      content:,
    )
  end
end
