# frozen_string_literal: true

# Entitlement check for the Gumroad Walks iOS app.
#
# The iOS client sends `Transaction.jsonRepresentation` (a StoreKit 2 signed
# JWS) on every Walks API call via the `X-Apple-Transaction-JWS` header.
# `AppStoreWalksJwsVerifier` performs Apple-Root-CA-G3-anchored chain +
# signature + payload checks. Verification is sub-millisecond and offline,
# so we run it inline per request rather than caching subscription state
# in our database.
#
# When we eventually need authoritative per-user subscription state (for
# server-initiated emails, dunning, etc.) the path is App Store Server
# Notifications V2 webhooks -> DB column on User; until then the JWS the
# client holds is the source of truth.
module User::GumroadWalksEntitlement
  extend ActiveSupport::Concern

  # Returns true iff the JWS verifies, productId == ProSub, expiresDate is
  # in the future, and revocationDate is nil. Pass the raw JWS string from
  # the X-Apple-Transaction-JWS header.
  def gumroad_walks_subscribed?(transaction_jws:)
    AppStoreWalksJwsVerifier.verify(transaction_jws).valid?
  end
end
