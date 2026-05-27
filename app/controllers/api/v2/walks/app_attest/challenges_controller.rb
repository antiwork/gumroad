# frozen_string_literal: true

# Issues a short-lived, single-use server nonce for the App Attest flow.
# The iOS app GETs (well, POSTs — no body, but POST avoids the request
# from being prefetched/cached) a fresh challenge before every attestation
# and every assertion. The challenge is the source of nonce material that
# `DCAppAttestService` signs over via `clientDataHash`.
class Api::V2::Walks::AppAttest::ChallengesController < Api::V2::BaseController
  skip_before_action :verify_authenticity_token, only: [:create]

  def create
    render json: { challenge: WalksAppAttestChallenge.issue! }
  end
end
