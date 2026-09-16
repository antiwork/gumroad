# frozen_string_literal: true

# Asks Stripe whether it can resolve a new bank account's routing number before we store it.
#
# For most countries our format regex is the whole story, but some bank codes are validated by
# Stripe against a per-entry directory, and which entries exist is not a shape: Stripe's EG
# directory resolves NBEGEGCX331 and refuses QNBAEGCX027 (gumroad-private#2638). A code it cannot
# resolve saves fine on our side and then never attaches, so every payout skips with "bank account
# was not correctly set up" and the seller is never told why. Tokenising the details is
# side-effect-free (no account, no external account) and answers the question at save time.
#
# Fail-open by design: only a rejection Stripe attributes to the routing number blocks the save.
# Anything else — timeouts, 5xx, rate limits, an unexpected error shape — is logged and the save
# proceeds exactly as it does today, so a Stripe blip cannot lock every seller out of the form.
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

  # Returns a seller-facing error message when Stripe cannot resolve the routing number, or nil
  # when the code resolves, the check does not apply, or Stripe could not be asked.
  def self.rejection_message_for(bank_account, previous_bank_account: nil)
    new(bank_account, previous_bank_account:).rejection_message
  end

  def initialize(bank_account, previous_bank_account: nil)
    @bank_account = bank_account
    @previous_bank_account = previous_bank_account
  end

  def rejection_message
    return unless applicable?
    return if routing_number_unchanged?

    probe_stripe
    nil
  rescue Stripe::InvalidRequestError => e
    return rejection_message_text if routing_number_rejection?(e)

    fail_open(e)
  rescue Stripe::StripeError => e
    fail_open(e)
  end

  private
    attr_reader :bank_account, :previous_bank_account

    def applicable?
      DIRECTORY_CHECKED_BANK_ACCOUNT_TYPES.any? { |type| bank_account.is_a?(type) } && routing_number.present?
    end

    # A seller correcting their holder name or account number under a code Stripe already attached
    # gets no probe: the directory has answered for that code. A previous row that never attached is
    # exactly the case this check exists for, so re-saving its code is probed.
    def routing_number_unchanged?
      previous_bank_account.present? &&
        previous_bank_account.instance_of?(bank_account.class) &&
        previous_bank_account.stripe_external_account_id.present? &&
        previous_bank_account.stripe_external_account_routing_number == routing_number
    end

    def routing_number
      bank_account.stripe_external_account_routing_number
    end

    def probe_stripe
      Stripe::Token.create(
        {
          bank_account: {
            country: bank_account.stripe_external_account_country,
            currency: bank_account.stripe_external_account_currency,
            routing_number:,
            account_number: bank_account.send(:account_number_decrypted),
          },
        },
        { client: Stripe::StripeClient.new(STRIPE_CLIENT_OPTIONS) }
      )
    end

    def routing_number_rejection?(error)
      return true if error.code == "routing_number_invalid"

      error.param.to_s == "bank_account[routing_number]"
    end

    def rejection_message_text
      message = "Our payment partner couldn't find a bank for the #{bank_account.routing_fields_sentence}."
      if BRANCH_SUFFIXED_BIC_REGEX.match?(routing_number)
        message += " Use the 8-character SWIFT/BIC code instead: #{routing_number.first(8)} rather than #{routing_number}."
      else
        message += " Please check it against the SWIFT/BIC code your bank publishes."
      end
      message
    end

    def fail_open(error)
      Rails.logger.warn(
        "[BankCodeDirectoryCheck] Stripe probe failed open for user #{bank_account.user_id} " \
        "(#{bank_account.class.name}): #{error.class}: #{error.message}"
      )
      nil
    end
end
