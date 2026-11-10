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
# Which of the two Stripe is asked about is decided by the payout shape the row sends, not by us:
# a country that collects a routing number is asked to resolve THAT number, and a row whose payload
# carries none (every SEPA IBAN, for instance) is asked to resolve the bank the account number
# itself points at. Both questions are answered by the same directory, so both are worth asking
# before we store the row — see ACCOUNT_NUMBER_CHECKED_BANK_ACCOUNT_TYPES for the second path.
#
# Fail-open: only a rejection Stripe attributes to one of those two lookups blocks the save.
# Anything else is logged and the save proceeds, so a Stripe blip cannot lock every seller out of
# the form.
class BankCodeDirectoryCheck
  # Opt-in per country, for rows that DO send Stripe a routing number. Add a class here only after
  # probing that Stripe's directory (not its format check) is the layer that refuses real seller
  # input for that country.
  DIRECTORY_CHECKED_BANK_ACCOUNT_TYPES = [EgyptBankAccount].freeze

  # The second path: rows whose Stripe payload carries NO routing number, so the only detail sent is
  # the account number and the bank is looked up from it. The first list can never reach these —
  # `routing_number.present?` is false by construction on every SEPA IBAN — and without this path
  # they save silently and never attach.
  #
  # Measured live 2026-11-10 (gumroad-private#4495): a seller on a Swedish account saved a GB IBAN
  # whose bank is absent from Stripe's directory. The probe below was skipped, the row stored with
  # `stripe_bank_account_id` NULL, the form reported success, and Stripe answered
  # `bank_account_unusable` / "We couldn't find the bank for this account number" on the attach that
  # followed. Re-entering any account at that bank misses the same way, so the seller has to be told
  # at save time, and told to use a different bank.
  ACCOUNT_NUMBER_CHECKED_BANK_ACCOUNT_TYPES = [IbanBankAccount].freeze

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
    return account_number_rejection if account_number_rejection?(e)

    fail_open(e)
  rescue Stripe::StripeError => e
    fail_open(e)
  end

  private
    attr_reader :bank_account, :previous_bank_account

    def applicable?
      return false if account_number_of(bank_account).blank?

      if routing_number.present?
        DIRECTORY_CHECKED_BANK_ACCOUNT_TYPES.any? { |type| bank_account.is_a?(type) }
      else
        ACCOUNT_NUMBER_CHECKED_BANK_ACCOUNT_TYPES.any? { |type| bank_account.is_a?(type) }
      end
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
      # The payload mirrors StripeMerchantAccountManager#bank_account_hash: the routing number key is
      # ADDED only when the row sends one. Passing `routing_number: nil` instead would ask Stripe a
      # different question than the attach does, so the answer would not be evidence about the attach.
      details = {
        country: bank_account.stripe_external_account_country,
        currency: bank_account.stripe_external_account_currency,
        account_number: account_number_of(bank_account),
      }
      details[:routing_number] = routing_number if routing_number.present?

      Stripe::Token.create(
        { bank_account: details },
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

    # An account-number miss means one of two different things, and which one it is is decided by
    # what the payload carried — not by which box the seller filled in.
    #
    # A routing number was sent and it resolved, so only the branch inside the account number is
    # left, and the code resolving no better under an 8-character SWIFT/BIC is what to name.
    #
    # With no routing number in the payload the account number was the ONLY detail Stripe had, so
    # the miss is the bank itself. Re-entering any account at that bank misses the same way, so
    # naming the account number as something to check would send the seller round a loop: the one
    # piece of advice that changes the outcome is a different bank.
    def account_number_rejection
      return missing_branch_rejection if routing_number.present?

      Rejection.new(
        message: "Our payment partner couldn't find the bank this account number belongs to, so it " \
                 "can't be used for payouts. Please enter an account number at a different bank.",
        field: :account_number
      )
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
