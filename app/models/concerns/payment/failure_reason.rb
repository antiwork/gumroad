# frozen_string_literal: true

module Payment::FailureReason
  extend ActiveSupport::Concern

  CANNOT_PAY = "cannot_pay"
  DEBIT_CARD_LIMIT = "debit_card_limit"
  INSUFFICIENT_FUNDS = "insufficient_funds"
  BANK_ACCOUNT_NOT_FOUND_AT_STRIPE = "bank_account_not_found_at_stripe"
  CURRENCY_MISMATCH = "currency_mismatch"
  DESTINATION_CURRENCY_MISMATCH = "destination_currency_mismatch"
  BELOW_STRIPE_PAYOUT_MINIMUM = "below_stripe_payout_minimum"
  STRIPE_INTERVENTION_REQUIRED = "stripe_intervention_required"
  PAYPAL_PAYOUT_FAILED = "PAYPAL payout failed"

  # PayPal rejections that describe the destination PayPal account itself rather than something
  # about this one attempt, so re-sending the same payout to the same address can never succeed.
  # Both are properties of the receiving account: 3148 means the country on that account's address
  # cannot receive PayPal payments at all, and 14159 means the account cannot receive US dollars
  # (Gumroad always pays PayPal out in USD).
  #
  # Everything else in PAYPAL_MASS_PAY stays retryable. In particular a locked or inactive
  # receiving account (3015) and a declined transaction (9302) are deliberately NOT here: the
  # seller can clear those with PayPal without touching the address we hold, and the block below
  # is keyed on the address, so it would have no way to notice they had been resolved.
  TERMINAL_PAYPAL_FAILURE_REASONS = ["PAYPAL 3148", "PAYPAL 14159"].freeze

  # What the seller is told when a payout hits one of those rejections. Written in the second
  # person because, unlike every other PayPal failure note, these are shown to the seller: the
  # money stops moving until they act, so they have to know PayPal is the blocker and what to do.
  TERMINAL_PAYPAL_FAILURE_SELLER_REASONS = {
    "PAYPAL 3148" => "PayPal will not send payouts to your PayPal account, because payments cannot be received in the country on that account's address",
    "PAYPAL 14159" => "PayPal will not send your payout, because your PayPal account cannot receive US dollars",
  }.freeze

  # What the seller can actually do about it, and what happens next. Both halves have to be true
  # for the individual seller, so each is chosen separately.
  #
  # The fix depends on whether Gumroad does bank payouts in the seller's country at all. Most
  # sellers hitting these rejections are in countries where we do NOT (four out of five, largely
  # Ukraine, because PayPal is the only rail we offer there) — telling them to add a bank account
  # would be advice they cannot follow, which is the same kind of dead end this change exists to
  # remove.
  TERMINAL_PAYPAL_FAILURE_SELLER_FIX_WITH_BANK =
    "Add a bank account in your payout settings, or use a different PayPal account that can receive US dollars."
  TERMINAL_PAYPAL_FAILURE_SELLER_FIX_PAYPAL_ONLY =
    "PayPal is the only payout method we can offer in your country, so to get paid you'll need to use a " \
    "different PayPal account that can receive US dollars. You can change it in your payout settings."

  # What happens after they fix it. Three consecutive failed payouts to the same destination trip
  # an automatic hold on the whole account (Payment#pause_payouts_after_repeated_failures), and
  # sellers here have failed dozens of times, so many are already holding one. That hold is checked
  # in Payouts.is_user_payable BEFORE we ever reach the PayPal processor, and nothing a seller can
  # do to their own payout settings lifts it: changing the PayPal address clears only a
  # Stripe-sourced hold (UpdatePayoutMethod), and the one automatic release job covers
  # chargeback-rate holds, not this one. Someone on support has to resume it — so promising the
  # next payout date would be a second false promise on top of the one we are fixing.
  #
  # The wording does not say what CAUSED the hold. A hold that reaches this message can equally be
  # one support placed, one Stripe asked for, or one the seller set on themselves in their own
  # payout settings; blaming it on the failed payouts would be wrong in most of those cases. What
  # is always true is that a hold is on the account and it is why fixing the payout method alone
  # will not release the money, so that is all we claim.
  TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP =
    "Your balance is safe in the meantime and will be paid out on the next payout date after a working payout method is on file."
  TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED =
    "Your balance is safe. Payouts on your account are also on hold, so once a working payout method is on file, " \
    "reply to this message and we will review the hold and release your balance."

  PAYPAL_MASS_PAY = {
    PAYPAL_PAYOUT_FAILED => "PayPal rejected the payout without returning a reason code",
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

  # Terminal rejections are absent from this list on purpose: the retry loop is stopped for them
  # and the seller is told directly (see TERMINAL_PAYPAL_FAILURE_SELLER_REASONS), so there is no
  # support-facing "what to tell them" entry to write.
  PAYPAL_FAILURE_SOLUTIONS = {
    "PAYPAL 11711" => {
      reason: "per-transaction sending limit exceeded",
      solution: "Contact PayPal to get receiving limit on the account increased. If that's not possible, Gumroad can split their payout, please contact Gumroad Support"
    },
    "PAYPAL 3015" => {
      reason: "receiver's account is locked or inactive",
      solution: "Log in to your PayPal account and ensure there are no restrictions on it, or contact PayPal Support for more information"
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
    "bank_account_not_found_at_stripe" => {
      reason: "the bank account on file at Stripe was replaced, so payouts can no longer be sent to the saved reference",
      solution: "Re-add the bank account in payout settings to refresh the saved reference",
    },
    "bank_account_restricted" => {
      reason: "the bank account has restrictions on either the type, or the number, of payouts allowed. This normally indicates that the bank account is a savings or other non-checking account",
      solution: "Confirm the bank account entered in payout settings",
    },
    "below_stripe_payout_minimum" => {
      reason: "the payout amount was below the minimum amount the payout processor can send in your bank account's currency",
      solution: "No action needed — the balance will roll into your next payout once it grows past the minimum",
    },
    "stripe_intervention_required" => {
      reason: "the payout processor requires additional verification before it can send payouts to this account",
      solution: "Check your email for a message from Stripe about resolving the outstanding requirements, or complete them in payout settings",
    },
    "cannot_pay" => {
      reason: "Stripe is unable to create payouts to this account",
      solution: "Complete any outstanding requirements in payout settings. If the issue persists, contact Gumroad Support",
    },
    "currency_mismatch" => {
      reason: "a leftover balance held in a currency that no longer matches the payout account is blocking this payout",
      solution: "Gumroad needs to reconcile a residual balance from a previous payout currency before payouts can resume. Contact Gumroad Support",
    },
    "destination_currency_mismatch" => {
      reason: "the payout currency does not match any bank account configured to receive it on the connected Stripe account",
      solution: "Confirm a bank account that accepts this currency is set up in payout settings. If the issue persists, contact Gumroad Support",
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

      # A terminal PayPal rejection stops the weekly retry, so this note is the seller's only
      # explanation of why their money stopped moving — it names PayPal and the fix, and it is
      # shown to them on their Payouts page.
      if terminal_paypal_failure?
        user.add_payout_note(
          content: "Your payout on #{created_at.to_fs(:formatted_date_full_month)} could not be sent because " \
                   "#{TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.fetch(failure_reason)}. " \
                   "#{terminal_paypal_failure_seller_solution}",
          seller_visible: true
        )
        return
      end

      solution = if processor == PayoutProcessorType::PAYPAL
        PAYPAL_FAILURE_SOLUTIONS[failure_reason]
      elsif processor == PayoutProcessorType::STRIPE
        STRIPE_FAILURE_SOLUTIONS[failure_reason]
      end

      return unless solution.present?

      content = "Payout via #{processor.capitalize} on #{created_at} failed because #{solution[:reason]}. Solution: #{solution[:solution]}."
      # Stripe failures are explained to the seller in the banner on their Payouts page (the page
      # strips the "via Stripe " out of the sentence). PayPal failures have always been excluded
      # from that banner, so they stay support-only.
      user.add_payout_note(content:, seller_visible: processor != PayoutProcessorType::PAYPAL)
    end
end
