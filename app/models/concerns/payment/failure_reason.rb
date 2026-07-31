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
  PROCESSOR_RATE_LIMITED = "processor_rate_limited"
  PROCESSOR_UNAVAILABLE = "processor_unavailable"
  UNREVERSED_INTERNAL_TRANSFER = "unreversed_internal_transfer"
  PAYOUT_OUTCOME_UNKNOWN = "payout_outcome_unknown"
  PAYPAL_PAYOUT_FAILED = "PAYPAL payout failed"

  # Failures caused by us or by the processor being unreachable, never by the seller's payout
  # details. They must not count toward MAX_CONSECUTIVE_FAILED_PAYOUTS, and they get no
  # STRIPE_FAILURE_SOLUTIONS entry, because there is nothing for the seller to fix.
  TRANSIENT_REASONS = [PROCESSOR_RATE_LIMITED, PROCESSOR_UNAVAILABLE, UNREVERSED_INTERNAL_TRANSFER,
                       PAYOUT_OUTCOME_UNKNOWN].freeze

  # Failures where money may ALREADY have left Gumroad and we cannot tell from our own records:
  #   UNREVERSED_INTERNAL_TRANSFER — funds are on the seller's connected account because the
  #     reversal failed.
  #   PAYOUT_OUTCOME_UNKNOWN — a Stripe request was in flight when the connection dropped, so
  #     Stripe may have accepted it while we recorded no id (the gem's idempotency key is per call,
  #     so a later retry is a new key and can move the money a second time).
  # `mark_failed!` returns the balances to `unpaid`, and neither the daily requeue NOR the weekly
  # batch reads failure_reason — so keeping these out of REQUEUEABLE_REASONS is not enough on its
  # own to stop re-payment. StripePayoutProcessor pauses the seller's payouts when it stamps one,
  # which is what actually holds the balance until a human reconciles against Stripe.
  UNACCOUNTED_MONEY_REASONS = [UNREVERSED_INTERNAL_TRANSFER, PAYOUT_OUTCOME_UNKNOWN].freeze

  # The subset an automated requeue may re-issue: failures raised before Stripe could accept
  # anything, so re-issuing cannot duplicate money.
  REQUEUEABLE_REASONS = [PROCESSOR_RATE_LIMITED, PROCESSOR_UNAVAILABLE].freeze

  # PayPal rejections we explain to the seller in their own words, because the seller has to change
  # something about the receiving PayPal account before the money can move. 3148 means the country
  # on that account's address cannot receive PayPal payments at all; 14159 means the account cannot
  # receive US dollars, and Gumroad always pays PayPal out in USD.
  #
  # Everything else in PAYPAL_MASS_PAY stays a support-only note. In particular a locked or inactive
  # receiving account (3015) and a declined transaction (9302) are deliberately NOT here: those are
  # about one attempt, not about what the seller holds.
  #
  # The keys are the rejections; the values are what the seller is told about each. Written in the
  # second person because, unlike every other PayPal failure note, these are shown to the seller:
  # they have to know PayPal is the blocker and what to do about it.
  EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS = {
    "PAYPAL 3148" => "PayPal will not send payouts to your PayPal account, because payments cannot be received in the country on that account's address",
    "PAYPAL 14159" => "PayPal will not send your payout, because your PayPal account cannot receive US dollars",
  }.freeze

  # Which of those rejections additionally STOP the weekly retry.
  #
  # Explaining a rejection and refusing to retry it are two different claims, and only the second
  # one needs proof that the seller cannot repair the account in place. 3148 is a property of the
  # address's country: PayPal does not receive payments there at all, and nothing the seller does
  # inside that account changes it, so re-sending is pure noise.
  #
  # 14159 is deliberately NOT here even though it is equally a property of the account, because
  # PayPal lets a recipient add and manage receive currencies on the same account
  # (https://www.paypal.com/c2/cshelp/article/how-do-i-manage-my-currencies-with-paypal-help116).
  # A seller who does that leaves the account and address unchanged, so an address-keyed block has
  # no way to notice the repair — one 14159 would freeze every future automatic payout to that email
  # indefinitely, clearable only by an admin-issued payout. Retrying a 14159 costs us a rejected
  # PayPal item a week; blocking it costs a seller who fixed their account their entire balance. The
  # seller still gets the explanation and the email; they are just not locked out while acting on it.
  #
  # Raising 14159 to retry-blocking needs evidence from production that these accounts do not
  # recover — a 14159 rejection with no later successful payout to the same address, across the
  # affected population — plus a recovery path (an expiry, or a support-triggered retry) so a seller
  # who does fix it is not stuck behind a permanent block.
  RETRY_BLOCKING_PAYPAL_FAILURE_REASONS = ["PAYPAL 3148"].freeze

  # Rejections the seller can clear on the PayPal account they already use, by adding US dollars to
  # the currencies that account accepts. Only 14159 qualifies: 3148 is about the country on the
  # account's address, which adding a currency does not change. Kept next to the retry lists because
  # it is the other half of the same distinction — this is exactly why 14159 is explained but still
  # retried, and the seller-facing copy has to offer the in-place fix rather than only telling them
  # to find another account.
  REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS = ["PAYPAL 14159"].freeze

  # Every code that stops the retries must also have seller-facing wording, because the payout walk
  # looks that wording up by code (Payment#terminal_paypal_failure_seller_note) while deciding
  # whether to re-explain the block. Without this, adding a code to one list and not the other
  # raises a KeyError inside the weekly payout run.
  raise "every retry-blocking PayPal rejection needs seller-facing wording" unless
    (RETRY_BLOCKING_PAYPAL_FAILURE_REASONS - EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS.keys).empty?

  # A rejection cannot be both repairable on the same account and a reason to stop retrying: the
  # whole argument for blocking is that no action inside the account changes the outcome. If the two
  # lists ever overlap, the seller is told to fix something in place while an address-keyed block
  # makes sure we never notice they did.
  raise "a rejection cannot be repairable in place and retry-blocking at once" unless
    (REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS & RETRY_BLOCKING_PAYPAL_FAILURE_REASONS).empty?

  # Kept as the name the rest of the payout code has always used for "do not retry this".
  TERMINAL_PAYPAL_FAILURE_REASONS = RETRY_BLOCKING_PAYPAL_FAILURE_REASONS

  # Retained name for the explanation copy, so callers that only render text are unaffected.
  TERMINAL_PAYPAL_FAILURE_SELLER_REASONS = EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS

  # The codes worth explaining to the seller, which is a SUPERSET of the retry-blocking ones. Used
  # by everything that writes or recognises the seller-facing note, so a seller whose rejection we
  # still retry is told about it just the same.
  EXPLAINED_PAYPAL_FAILURE_REASONS = EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS.keys.freeze

  # Whether a payout note is one of the terminal-PayPal explanations above.
  #
  # Recognising these by their wording is deliberate. They are the only payout notes that name
  # PayPal and the restriction to the seller, so the reason sentence identifies them without
  # needing a marker on the comment row — which matters because the notes we most need to
  # recognise are the ones already written to sellers before any marker existed.
  #
  # ⚠️ Rewording TERMINAL_PAYPAL_FAILURE_SELLER_REASONS therefore does not just change future
  # copy: it stops recognising every note already written, which would let the weekly pause note
  # bury explanations that are on real sellers' Payouts pages today, and would let the one-time
  # backfill write a second note to sellers who already have one. HISTORICAL_SELLER_REASONS
  # records every wording ever shipped, per rejection code, so a reword stays
  # backwards-compatible — add the old sentence under its code in the same commit that changes
  # the constant.
  HISTORICAL_SELLER_REASONS = {
    "PAYPAL 3148" => [
      "PayPal will not send payouts to your PayPal account, because payments cannot be received in the country on that account's address",
    ].freeze,
    "PAYPAL 14159" => [
      "PayPal will not send your payout, because your PayPal account cannot receive US dollars",
    ].freeze,
  }.freeze

  def self.terminal_paypal_explanation_note?(content)
    text = content.to_s
    all_seller_reasons.any? { |reason| text.include?(reason) }
  end

  # Whether a payout note is the explanation of one PARTICULAR rejection.
  #
  # A seller can be blocked on one PayPal address after having been rejected on another, so
  # "carries a terminal-PayPal explanation" is not the same question as "has been told about the
  # block they are under now". Anything deciding whether the seller still needs telling has to ask
  # this narrower one — otherwise a note about an address they abandoned counts as an explanation
  # of the current block, and they are left reading a stale date and possibly the wrong PayPal
  # restriction (the two rejections say different things).
  #
  # The pair that identifies a rejection in the note's own wording is its payout date and its
  # restriction sentence. Both come from the note the payment itself generates
  # (Payment#terminal_paypal_failure_seller_note), and the restriction is matched across every
  # wording ever shipped for that code so notes written before a reword still match.
  #
  # The PayPal address is deliberately not part of the match, even though a seller can be rejected
  # on two addresses on the same day with the same code. The note names no address, and its fix and
  # next-step halves come from the user rather than the payment, so two such notes are identical
  # text — treating one as explaining the other is right, and keying on the address would only write
  # the seller a second copy of what they are already reading.
  def self.terminal_paypal_explanation_note_for?(content, payment)
    text = content.to_s
    return false unless text.include?(payment.created_at.to_fs(:formatted_date_full_month))

    seller_reasons_for(payment.failure_reason).any? { |reason| text.include?(reason) }
  end

  def self.seller_reasons_for(failure_reason)
    ([TERMINAL_PAYPAL_FAILURE_SELLER_REASONS[failure_reason]] |
      HISTORICAL_SELLER_REASONS.fetch(failure_reason, [])).compact
  end
  private_class_method :seller_reasons_for

  def self.all_seller_reasons
    TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.values | HISTORICAL_SELLER_REASONS.values.flatten
  end
  private_class_method :all_seller_reasons

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

  # For a rejection the seller can clear without leaving the account they already use (14159), the
  # in-place repair is offered first, because it is the only fix that costs them nothing: no new
  # account, no new bank details, and no waiting on us. The other options still follow, since a
  # seller may prefer them.
  TERMINAL_PAYPAL_FAILURE_SELLER_FIX_IN_PLACE_WITH_BANK =
    "Sign in to PayPal and add US dollars to the currencies your account can receive. You can also add a bank " \
    "account in your payout settings, or use a different PayPal account that can receive US dollars."
  TERMINAL_PAYPAL_FAILURE_SELLER_FIX_IN_PLACE_PAYPAL_ONLY =
    "Sign in to PayPal and add US dollars to the currencies your account can receive. PayPal is the only payout " \
    "method we can offer in your country, so the alternative is to use a different PayPal account that can " \
    "receive US dollars, which you can change in your payout settings."

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
  # "Contact support" rather than "reply to this message": these constants are rendered into the
  # payout note shown on the Payouts page, which is not something a seller can reply to. The email
  # that carries the same message says "reply to this email" in its own template, where that is true.
  TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED =
    "Your balance is safe. Payouts on your account are also on hold, so once a working payout method is on file, " \
    "contact support and we will review the hold and release your balance."
  # A seller who paused their own payouts owns the switch, so the honest next step names it instead
  # of promising a payout date that will not arrive while their own pause is on.
  TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_SELF_PAUSED =
    "Your balance is safe. Payouts on your account are paused in your settings, so once a working payout method " \
    "is on file and you resume payouts there, your balance will be paid out on the next payout date."
  # Both pauses can be on at once, and naming only the hold would hide the half the seller has to
  # clear themselves — leaving them waiting on support for money their own toggle is still blocking.
  TERMINAL_PAYPAL_FAILURE_SELLER_NEXT_STEP_WHILE_PAUSED_AND_SELF_PAUSED =
    "Your balance is safe. Payouts on your account are also on hold, and paused in your settings. Once a working " \
    "payout method is on file, resume payouts in your settings and contact support so we can review the hold — " \
    "your balance will be paid out once both are cleared."

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

      # A rejection about the seller's own PayPal account gets a seller-visible note naming PayPal
      # and the fix, since nothing else on their Payouts page tells them why the money stopped.
      # Deliberately the wider EXPLAINED set rather than the retry-blocking one: a seller whose
      # payout we will retry next week still needs to know why this one failed and what to change.
      if explained_paypal_failure?
        user.add_payout_note(content: terminal_paypal_failure_seller_note, seller_visible: true)
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
