# frozen_string_literal: true

# Asks Stripe whether it can resolve a new bank account's details before we store it.
#
# Some countries' bank codes are validated by Stripe against a per-entry directory, and which
# entries exist is not a shape our regex can express. Details it cannot resolve save fine here and
# then never attach, so payouts skip with nothing shown to the seller. Tokenising the details is
# side-effect-free and answers the question at save time.
#
# Stripe resolves two separate things, and at least one country's directory answers for both: the
# routing number's entry, and the branch the account number points at (EG refuses an IBAN whose
# branch segment has no entry). Either miss leaves the row unattached, so both block the save.
#
# Fail-open: only a rejection Stripe attributes to one of those two lookups blocks the save.
# Anything else is logged and the save proceeds, so a Stripe blip cannot lock every seller out of
# the form.
class BankCodeDirectoryCheck
  # Opt-in per country. Add a class here only after probing that Stripe's directory (not its format
  # check) is the layer that refuses real seller input for that country.
  DIRECTORY_CHECKED_BANK_ACCOUNT_TYPES = [EgyptBankAccount].freeze

  # Short budget: this runs inside a settings-save request, before the row lock is taken.
  STRIPE_CLIENT_OPTIONS = { open_timeout: 5, read_timeout: 10, max_network_retries: 0 }.freeze
  private_constant :STRIPE_CLIENT_OPTIONS

  # An 11-character SWIFT/BIC is the 8-character primary code plus a branch suffix.
  BRANCH_SUFFIXED_BIC_REGEX = /\A[A-Z]{6}[A-Z0-9]{2}[A-Z0-9]{3}\z/
  private_constant :BRANCH_SUFFIXED_BIC_REGEX

  # The seller-facing message, and the input that answers it, so the form flags the field that has
  # to change rather than the one this check is named after.
  Rejection = Data.define(:message, :field)

  # Returns a Rejection when Stripe cannot resolve the details, or nil when it resolves them, the
  # check does not apply, or Stripe could not be asked.
  def self.rejection_for(bank_account, previous_bank_account: nil)
    new(bank_account, previous_bank_account:).rejection
  end

  def initialize(bank_account, previous_bank_account: nil)
    @bank_account = bank_account
    @previous_bank_account = previous_bank_account
  end

  def rejection
    return unless applicable?
    return if already_resolved?

    probe_stripe
    nil
  rescue Stripe::InvalidRequestError => e
    return missing_routing_number_rejection if routing_number_rejection?(e)
    return missing_branch_rejection if account_number_rejection?(e)

    fail_open(e)
  rescue Stripe::StripeError => e
    fail_open(e)
  end

  private
    attr_reader :bank_account, :previous_bank_account

    def applicable?
      DIRECTORY_CHECKED_BANK_ACCOUNT_TYPES.any? { |type| bank_account.is_a?(type) } && routing_number.present?
    end

    # A seller correcting their holder name over details Stripe already attached gets no probe: the
    # directory has answered for that routing number and that account number. A previous row that
    # never attached is exactly the case this check exists for, so re-saving its details is probed.
    # A changed account number is a new question even under an unchanged code, because the branch
    # segment inside it is looked up on its own.
    def already_resolved?
      previous_bank_account.present? &&
        previous_bank_account.instance_of?(bank_account.class) &&
        previous_bank_account.stripe_external_account_id.present? &&
        previous_bank_account.stripe_external_account_routing_number == routing_number &&
        account_number_of(previous_bank_account) == account_number_of(bank_account)
    end

    def routing_number
      bank_account.stripe_external_account_routing_number
    end

    def account_number_of(account)
      account.send(:account_number_decrypted)
    end

    def probe_stripe
      Stripe::Token.create(
        {
          bank_account: {
            country: bank_account.stripe_external_account_country,
            currency: bank_account.stripe_external_account_currency,
            routing_number:,
            account_number: account_number_of(bank_account),
          },
        },
        { client: Stripe::StripeClient.new(STRIPE_CLIENT_OPTIONS) }
      )
    end

    def routing_number_rejection?(error)
      return true if error.code == "routing_number_invalid"

      error.param.to_s == "bank_account[routing_number]"
    end

    # Narrower than the routing-number predicate above: Stripe reports a plain format rejection as
    # account_number_invalid on the same param, and that must keep failing open.
    def account_number_rejection?(error)
      error.code == "bank_account_unusable" && error.param.to_s == "bank_account[account_number]"
    end

    def missing_routing_number_rejection
      message = "Our payment partner couldn't find a bank for the #{bank_account.routing_fields_sentence}."
      if BRANCH_SUFFIXED_BIC_REGEX.match?(routing_number)
        message += " Use the 8-character SWIFT/BIC code instead: #{routing_number.first(8)} rather than #{routing_number}."
      else
        message += " Please check it against the SWIFT/BIC code your bank publishes."
      end
      Rejection.new(message:, field: :bank_code)
    end

    # The code resolves here, and an 8-character SWIFT/BIC re-entered under it resolves no better,
    # so the branch inside the account number is what to name.
    def missing_branch_rejection
      Rejection.new(
        message: "Our payment partner couldn't find the branch this account number belongs to. " \
                 "Check the account number against your bank's records, or use an account at another branch.",
        field: :account_number
      )
    end

    def fail_open(error)
      Rails.logger.warn(
        "[BankCodeDirectoryCheck] Stripe probe failed open for user #{bank_account.user_id} " \
        "(#{bank_account.class.name}): #{error.class}: #{error.message}"
      )
      nil
    end
end
