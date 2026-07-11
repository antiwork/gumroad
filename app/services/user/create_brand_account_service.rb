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
class User::CreateBrandAccountService
  attr_reader :creator, :brand_user, :team_membership

  def initialize(creator:, email:, username:, name:, account_created_ip: nil)
    @creator = creator
    @email = email
    @username = username
    @name = name
    @account_created_ip = account_created_ip
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

    ActiveRecord::Base.transaction do
      @brand_user.save!

      creator.create_owner_membership_if_needed!
      @team_membership = @brand_user.seller_memberships.create!(
        user: creator,
        role: TeamMembership::ROLE_ADMIN,
      )
    end

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
end
