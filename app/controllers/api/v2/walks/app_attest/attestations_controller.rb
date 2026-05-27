# frozen_string_literal: true

# One-shot endpoint the iOS app hits the first time it ever talks to us. The
# request body is `{ key_id, attestation, challenge }` where `attestation` is
# the base64 CBOR blob from `DCAppAttestService.attestKey`. We verify the
# whole thing against Apple Root CA + the challenge we issued, and persist
# the attested EC P-256 public key so we can verify every subsequent
# assertion. Re-attesting the same keyId is a 422 (already known).
class Api::V2::Walks::AppAttest::AttestationsController < Api::V2::BaseController
  skip_before_action :verify_authenticity_token, only: [:create]

  def create
    result = WalksAppAttestVerifier.attest(
      key_id: params[:key_id].to_s,
      attestation_b64: params[:attestation].to_s,
      challenge: params[:challenge].to_s,
    )

    if result.valid?
      render json: { key_id: result.key.key_id, attested_at: result.key.attested_at }, status: :created
    else
      Rails.logger.warn("WalksAppAttest attestation rejected: #{result.error}")
      render json: { error: "Attestation rejected.", reason: result.error.to_s }, status: :unprocessable_entity
    end
  end
end
