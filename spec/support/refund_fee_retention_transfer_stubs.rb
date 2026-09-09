# frozen_string_literal: true

# US Gumroad-managed refunds now look up (then create) a grouped Stripe account
# debit before finishing local bookkeeping. Existing VCR cassettes predate that
# call and record :none, so every refund example that never cared about fee
# collection would otherwise raise UnhandledHTTPRequestError. Intercept only
# the refund-fee-retention transfer_group; every other Transfer.list/create
# still hits VCR or the example's own stub.
module RefundFeeRetentionTransferStubs
  def self.retention_group?(params)
    params.is_a?(Hash) && params[:transfer_group].to_s.start_with?("refund_fee_retention_")
  end

  def self.params_from(args, kwargs)
    args.first.is_a?(Hash) ? args.first : kwargs
  end
end

RSpec.configure do |config|
  config.before do
    allow(Stripe::Transfer).to receive(:list).and_wrap_original do |method, *args, **kwargs|
      params = RefundFeeRetentionTransferStubs.params_from(args, kwargs)
      if RefundFeeRetentionTransferStubs.retention_group?(params)
        []
      else
        method.call(*args, **kwargs)
      end
    end

    allow(Stripe::Transfer).to receive(:create).and_wrap_original do |method, *args, **kwargs|
      params = RefundFeeRetentionTransferStubs.params_from(args, kwargs)
      if RefundFeeRetentionTransferStubs.retention_group?(params)
        Stripe::Transfer.construct_from(
          id: "tr_test_refund_fee_#{params.dig(:metadata, :refund_id) || params.dig(:metadata, "refund_id") || "debit"}",
          object: "transfer",
          amount: params[:amount],
          currency: params[:currency],
          transfer_group: params[:transfer_group]
        )
      else
        method.call(*args, **kwargs)
      end
    end
  end
end
