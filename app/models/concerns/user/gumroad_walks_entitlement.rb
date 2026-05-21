# frozen_string_literal: true

# Entitlement check for the Gumroad Walks iOS app.
#
# **TEMPORARY STUB.** This module currently grants access to every
# authenticated user. The real implementation needs to verify the user's
# active App Store subscription (product id `ProSub`) by either:
#  - Storing state from App Store Server Notifications V2 webhooks, or
#  - Querying the App Store Server API on demand with a stored
#    `originalTransactionId` per user
#
# Both require capturing the user's App Store `originalTransactionId`
# the first time they subscribe (the iOS app would call a
# `POST /api/v2/walks/subscriptions/register` endpoint with the signed
# transaction JWS, we verify with Apple, persist the link to User).
#
# Until that ships, this returns true so the realtime + synthesis
# endpoints can be exercised end-to-end. See
# https://developer.apple.com/documentation/appstoreserverapi
module User::GumroadWalksEntitlement
  extend ActiveSupport::Concern

  def gumroad_walks_subscribed?
    # TODO(walks): verify against App Store Server API / stored
    # subscription state once the receipt-registration endpoint is
    # built. Currently any authenticated user can call the endpoints.
    true
  end
end
