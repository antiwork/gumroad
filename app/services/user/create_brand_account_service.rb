# frozen_string_literal: true

# Creates a brand account: a full Gumroad account (its own profile, products, and
# payout settings) that the creator administers from their existing login.
#
# The flow mirrors what accepting a team invitation does today, minus the invite
# email round-trip: we create the new User row, make sure the creator has an owner
# membership on their own account (needed so they can always switch back), and add
# them as an admin of the new account so it shows up in the account switcher.
#
# The new account gets a random password and must confirm its email (Devise sends
# the confirmation email on create). Publishing products is already blocked for
# unconfirmed accounts elsewhere, so no extra gating is needed here.
#
# When `use_existing_payout_setup` is true (the default in the UI), the creator's
# payout configuration is copied onto the new account so it skips payments
# onboarding: their compliance info (legal identity), payout currency, PayPal
# payment address, and bank account details are duplicated, and a brand-new Stripe
# Connect account is created from the copies in the background. We deliberately
# create a NEW Connect account instead of pointing both Gumroad accounts at the
# same one — sharing a Connect account would commingle the two accounts' balances
# and make webhook and payout attribution ambiguous, since everything downstream
# assumes one Connect account maps to one user.
class User::CreateBrandAccountService
  attr_reader :creator, :brand_user, :team_membership

  def initialize(creator:, email:, username:, name:, account_created_ip: nil, use_existing_payout_setup: false)
    @creator = creator
    @email = email
    @username = username
    @name = name
    @account_created_ip = account_created_ip
    @use_existing_payout_setup = use_existing_payout_setup
  end

  # Returns true when the brand account was created. On failure, validation
  # messages are available on #error_message.
  def perform
    # The brand account must have its own email — it gets its own login and
    # confirmation email. Without this check, reusing the creator's email would
    # still fail on the email uniqueness validation, but with a generic
    # "Email has already been taken" that doesn't explain what to do instead.
    if @email.to_s.strip.casecmp?(creator.email.to_s)
      @error_message = "The new account needs its own email address, different from your current account."
      return false
    end

    @brand_user = User.new(
      email: @email,
      username: @username,
      name: @name,
      password: Devise.friendly_token,
      account_created_ip: @account_created_ip,
    )
    @brand_user.tos_agreements.build(ip: @account_created_ip) if @account_created_ip.present?

    if @use_existing_payout_setup
      # The payout currency and PayPal address are plain columns on User, so they
      # can be copied before the initial save; the compliance info and bank
      # account are separate records copied after the user row exists (below).
      @brand_user.currency_type = creator.currency_type if creator.currency_type.present?
      @brand_user.payment_address = creator.payment_address if creator.payment_address.present?
    end

    ActiveRecord::Base.transaction do
      @brand_user.save!

      creator.create_owner_membership_if_needed!
      @team_membership = @brand_user.seller_memberships.create!(
        user: creator,
        role: TeamMembership::ROLE_ADMIN,
      )

      port_payout_setup! if @use_existing_payout_setup
    end

    # The Stripe API call happens outside the transaction (and outside the
    # request) so a slow or failing Stripe response can't block or roll back
    # the account creation itself.
    enqueue_stripe_account_creation if @ported_bank_account

    true
  rescue ActiveRecord::RecordInvalid => e
    @error_message = e.record.errors.full_messages.first
    false
  rescue ActiveRecord::RecordNotUnique
    # A concurrent request can slip past the model-level uniqueness checks and
    # hit the database's unique index instead, which raises RecordNotUnique
    # rather than RecordInvalid. Treat it the same as a validation failure.
    @error_message = "An account with that email or username already exists."
    false
  end

  attr_reader :error_message

  private
    def port_payout_setup!
      copy_compliance_info!
      copy_bank_account!
    end

    def copy_compliance_info!
      source = creator.alive_user_compliance_info
      return if source.nil?

      copy = source.dup
      copy.user = brand_user
      # The new account has no Stripe Connect account yet, so the background job
      # that syncs new compliance info to Stripe would be a no-op — skip
      # enqueueing it. The Connect account we create below is built from this
      # record directly.
      copy.skip_stripe_job_on_create = true
      copy.save!
    end

    def copy_bank_account!
      source = creator.active_bank_account
      # Debit-card payout "bank accounts" are backed by a stored credit card
      # record and a Stripe card token that belong to the creator's account;
      # neither can be shared with or cloned onto another user. Creators paying
      # out to a debit card set that up fresh on the new account.
      return if source.nil? || source.is_a?(CardBankAccount)

      copy = source.dup
      copy.user = brand_user
      # These identifiers point at the creator's existing Stripe Connect account.
      # The copy gets fresh ones when the new account's own Connect account is
      # created and the bank details are synced to it.
      copy.stripe_bank_account_id = nil
      copy.stripe_fingerprint = nil
      copy.stripe_connect_account_id = nil
      copy.state = "unverified"
      copy.save!

      @ported_bank_account = copy
    end

    def enqueue_stripe_account_creation
      # These mirror the guards inside StripeMerchantAccountManager.create_account
      # that would make it raise (unsupported country, blocked country, missing
      # TOS agreement). Checking here avoids enqueueing a job that can only fail.
      return unless brand_user.native_payouts_supported?
      return if brand_user.tos_agreements.empty?
      country_code = brand_user.alive_user_compliance_info&.legal_entity_country_code
      return if StripeMerchantAccountManager::NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES.include?(country_code)

      CreateStripeMerchantAccountWorker.perform_async(brand_user.id)
    end
end
