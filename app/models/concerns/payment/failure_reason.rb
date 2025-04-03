# frozen_string_literal: true

module Payment::FailureReason
  extend ActiveSupport::Concern

  CANNOT_PAY = "cannot_pay"
  DEBIT_CARD_LIMIT = "debit_card_limit"
  INSUFFICIENT_FUNDS = "insufficient_funds"

  PAYPAL_MASS_PAY = {
    "PAYPAL 1000" => "Unknown error",
    "PAYPAL 1001" => "Receiver's account is invalid",
    "PAYPAL 1002" => "Sender has insufficient funds",
    "PAYPAL 1003" => "User's country is not allowed",
    "PAYPAL 1004" => "User funding source is ineligible",
    "PAYPAL 3004" => "Cannot pay self",
    "PAYPAL 3014" => "Sender's account is locked or inactive",
    "PAYPAL 3015" => "Receiver's account is locked or inactive",
    "PAYPAL 3016" => "Either the sender or receiver exceeded the transaction limit",
    "PAYPAL 3017" => "Spending limit exceeded",
    "PAYPAL 3047" => "User is restricted",
    "PAYPAL 3078" => "Negative balance",
    "PAYPAL 3148" => "Receiver's address is in a non-receivable country or a PayPal zero country",
    "PAYPAL 3501" => "Email address invalid; try again with a valid email ID",
    "PAYPAL 3535" => "Invalid currency",
    "PAYPAL 3547" => "Sender's address is located in a restricted State (e.g., California)",
    "PAYPAL 3558" => "Receiver's address is located in a restricted State (e.g., California)",
    "PAYPAL 3769" => "Market closed and transaction is between 2 different countries",
    "PAYPAL 4001" => "Internal error",
    "PAYPAL 4002" => "Internal error",
    "PAYPAL 8319" => "Zero amount",
    "PAYPAL 8330" => "Receiving limit exceeded",
    "PAYPAL 8331" => "Duplicate mass payment",
    "PAYPAL 9302" => "Transaction was declined",
    "PAYPAL 11711" => "Per-transaction sending limit exceeded",
    "PAYPAL 14159" => "Transaction currency cannot be received by the recipient",
    "PAYPAL 14550" => "Currency compliance",
    "PAYPAL 14761" => "The mass payment was declined because the secondary user sending the mass payment has not been verified",
    "PAYPAL 14763" => "Regulatory review - Pending",
    "PAYPAL 14764" => "Regulatory review - Blocked",
    "PAYPAL 14765" => "Receiver is unregistered",
    "PAYPAL 14766" => "Receiver is unconfirmed",
    "PAYPAL 14767" => "Receiver is a youth account",
    "PAYPAL 14800" => "POS cumulative sending limit exceeded"
  }
  private_constant :PAYPAL_MASS_PAY

  PAYPAL_FAILURE_SOLUTIONS = {
    "PAYPAL 11711" => {
      reason: "per-transaction sending limit exceeded",
      solution: "Contact PayPal to get receiving limit on the account increased. If that's not possible, Gumroad can split their payout, please contact Gumroad Support"
    },
    "PAYPAL 14159" => {
      reason: "transaction currency cannot be received by the recipient",
      solution: "Use a different PayPal account which supports receiving USD"
    },
    "PAYPAL 3015" => {
      reason: "receiver's account is locked or inactive",
      solution: "Log in to your PayPal account and ensure there are no restrictions on it, or contact PayPal Support for more information"
    },
    "PAYPAL 3148" => {
      reason: "receiver's address is in a non-receivable country or a PayPal zero country",
      solution: "Use a different PayPal account which supports receiving USD"
    },
    "PAYPAL 8330" => {
      reason: "receiving limit exceeded",
      solution: "Reach out to PayPal support"
    },
    "PAYPAL 9302" => {
      reason: "transaction was declined",
      solution: "Reach out to PayPal support"
    }
  }
  private_constant :PAYPAL_FAILURE_SOLUTIONS

  STRIPE_FAILURE_SOLUTIONS = {
    "account_closed" => {
      reason: "the bank account has been closed",
      solution: "Use another bank account",
    },
    "account_frozen" => {
      reason: "the bank account has been frozen",
      solution: "Use another bank account",
    },
    "bank_account_restricted" => {
      reason: "the bank account has restrictions on either the type, or the number, of payouts allowed. This normally indicates that the bank account is a savings or other non-checking account",
      solution: "Confirm the bank account entered in payout settings",
    },
    "could_not_process" => {
      reason: "the bank could not process this payout",
      solution: "Confirm the bank account entered in payout settings. If it's correct, update to a new bank account",
    },
    "debit_card_limit" => {
      reason: "payouts to debit cards have a $3,000 per payout limit",
      solution: "Use a bank account to receive payouts instead of a debit card",
    },
    "expired_card" => {
      reason: "the card has expired",
      solution: "Replace the card with a new card and/or bank account",
    },
    "incorrect_account_holder_address" => {
      reason: "the bank notified us that the bank account holder address on file is incorrect",
      solution: "Confirm the bank account holder details entered in payout settings",
    },
    "incorrect_account_holder_name" => {
      reason: "the bank notified us that the bank account holder name on file is incorrect",
      solution: "Confirm the bank account holder details entered in payout settings",
    },
    "invalid_account_number" => {
      reason: "the routing number seems correct, but the account number is invalid",
      solution: "Confirm the bank account entered in payout settings",
    },
    "invalid_card" => {
      reason: "the card is invalid",
      solution: "Replace the card with a new card and/or bank account",
    },
    "invalid_currency" => {
      reason: "the bank was unable to process this payout because of its currency. This is probably because the bank account cannot accept payments in that currency",
      solution: "Add a bank account that can accept local currency",
    },
    "lost_or_stolen_card" => {
      reason: "the card is marked as lost or stolen",
      solution: "Replace the card with a new card and/or bank account",
    },
    "no_account" => {
      reason: "the bank account details on file are probably incorrect. No bank account could be located with those details",
      solution: "Confirm the bank account entered in payout settings",
    },
    "refer_to_card_issuer" => {
      reason: "the card is invalid",
      solution: "Reach out to their bank",
    },
    "unsupported_card" => {
      reason: "the bank no longer supports payouts to this card",
      solution: "Change the card used for payouts",
    },
  }
  private_constant :STRIPE_FAILURE_SOLUTIONS

  private
    def add_payment_failure_reason_comment
      return unless failure_reason.present?

      solution = if processor == PayoutProcessorType::PAYPAL
        PAYPAL_FAILURE_SOLUTIONS[failure_reason]
      elsif processor == PayoutProcessorType::STRIPE
        STRIPE_FAILURE_SOLUTIONS[failure_reason]
      end

      return unless solution.present?

      content = "Payout via #{processor.capitalize} on #{created_at} failed because #{solution[:reason]}. Solution: #{solution[:solution]}."
      user.add_payout_note(content:)
    end
end
