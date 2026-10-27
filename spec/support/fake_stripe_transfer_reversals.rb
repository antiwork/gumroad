# frozen_string_literal: true

# Stateful Stripe transfer endpoints behind WebMock, so the real SDK builds requests and parses errors.
# The fake owns transfer capacity and checks it when a reversal is created, so overlaps are deterministic.
class FakeStripeTransferReversals
  API = %r{\Ahttps://api\.stripe\.com/v1/}

  attr_reader :requests
  attr_accessor :before_reversal

  def initialize
    @transfers = {}
    @reversals = Hash.new { |hash, key| hash[key] = [] }
    @idempotent_responses = {}
    @requests = []
    @failures = {}
  end

  def add_transfer(id, amount:, currency: "usd", amount_reversed: 0)
    @transfers[id] = { id:, object: "transfer", amount:, amount_reversed:, currency: }
  end

  def fail_next_reversal(transfer_id, message)
    @failures[[:reversal, transfer_id]] = message
  end

  def fail_next_reversal_list(transfer_id, status: 500)
    @failures[[:reversal_list, transfer_id]] = status
  end

  def transfer(id) = @transfers.fetch(id)

  def reversals(transfer_id) = @reversals[transfer_id]

  def reversal_posts = requests.select { _1[:action] == :create_reversal }

  # Another refund's reversal landing outside the code under test.
  def reverse!(transfer_id, amount:, refund_id:)
    reversal = build_reversal(transfer_id, amount, refund_id)
    @transfers[transfer_id][:amount_reversed] += amount
    @reversals[transfer_id] << reversal
    reversal
  end

  def respond(request)
    path = request.uri.path.delete_prefix("/v1/")
    if request.method == :get && (match = path.match(%r{\Atransfers/([^/]+)/reversals\z}))
      list_reversals(match[1])
    elsif request.method == :post && (match = path.match(%r{\Atransfers/([^/]+)/reversals\z}))
      create_reversal(match[1], Rack::Utils.parse_nested_query(request.body), request.headers["Idempotency-Key"])
    elsif request.method == :get && (match = path.match(%r{\Atransfers/(tr_[^/]+)\z}))
      record(:retrieve, match[1])
      @transfers.key?(match[1]) ? ok(@transfers[match[1]]) : error(404, "invalid_request_error", "No such transfer: '#{match[1]}'")
    elsif request.method == :get && path == "transfers"
      record(:list, nil)
      ok(object: "list", data: [], has_more: false, url: "/v1/transfers")
    elsif request.method == :get && (match = path.match(%r{\Arefunds/([^/]+)\z}))
      ok(id: match[1], object: "refund", balance_transaction: "txn_#{match[1]}")
    elsif request.method == :get && (match = path.match(%r{\Abalance_transactions/txn_([^/]+)\z}))
      # Settles at par: these examples only use transfers in the account's own currency or USD.
      reversal = @reversals.values.flatten.find { _1[:destination_payment_refund] == match[1] }
      ok(id: "txn_#{match[1]}", object: "balance_transaction", net: -reversal.fetch(:amount))
    else
      raise "FakeStripeTransferReversals has no route for #{request.method.upcase} #{request.uri}"
    end
  end

  private
    def list_reversals(id)
      record(:list_reversals, id)
      status = @failures.delete([:reversal_list, id])
      return error(status, "api_error", "Stripe is unavailable") if status

      ok(object: "list", data: @reversals[id], has_more: false, url: "/v1/transfers/#{id}/reversals")
    end

    def create_reversal(id, params, idempotency_key)
      amount = params.fetch("amount").to_i
      refund_id = params.dig("metadata", "refund_id")
      record(:create_reversal, id, amount:, refund_id:, idempotency_key:)
      return @idempotent_responses[idempotency_key] if idempotency_key && @idempotent_responses.key?(idempotency_key)

      before_reversal&.call(id, refund_id)
      message = @failures.delete([:reversal, id])
      return error(400, "invalid_request_error", message) if message

      transfer = @transfers.fetch(id)
      remaining = transfer[:amount] - transfer[:amount_reversed]
      return error(400, "invalid_request_error", "The transfer #{id} is already fully reversed.") if remaining.zero?
      if amount > remaining
        return error(400, "invalid_request_error",
                     format("This transfer only has ($%.2f) remaining to reverse. We cannot reverse ($%.2f).", remaining / 100.0, amount / 100.0))
      end

      response = ok(reverse!(id, amount:, refund_id:))
      @idempotent_responses[idempotency_key] = response if idempotency_key
      response
    end

    def build_reversal(transfer_id, amount, refund_id)
      sequence = @reversals.values.sum(&:size) + 1
      { id: "trr_fake_#{sequence}", object: "transfer_reversal", amount:, currency: @transfers.fetch(transfer_id)[:currency],
        transfer: transfer_id, destination_payment_refund: "pyr_fake_#{sequence}", metadata: { refund_id: refund_id.to_s } }
    end

    def record(action, transfer_id, **details)
      @requests << { action:, transfer_id:, **details }
    end

    def ok(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json", "Request-Id" => "req_fake" } }
    end

    # Stripe-Should-Retry keeps the SDK's network retries from replaying a deliberate failure.
    def error(status, type, message)
      { status:, body: { error: { type:, message: } }.to_json,
        headers: { "Content-Type" => "application/json", "Request-Id" => "req_fake", "Stripe-Should-Retry" => "false" } }
    end
end
