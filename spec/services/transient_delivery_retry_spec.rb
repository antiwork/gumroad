# frozen_string_literal: true

require "spec_helper"

describe TransientDeliveryRetry do
  before { allow(described_class).to receive(:sleep) }

  it "returns the block's value when it succeeds first time" do
    calls = 0
    result = described_class.call(context: "test") do
      calls += 1
      :sent
    end

    expect(result).to eq(:sent)
    expect(calls).to eq(1)
  end

  it "retries a connection-establishment failure and returns the recovered value" do
    calls = 0
    result = described_class.call(context: "test") do
      calls += 1
      raise Socket::ResolutionError, "getaddrinfo: Temporary failure in name resolution" if calls < 3
      :sent
    end

    expect(result).to eq(:sent)
    expect(calls).to eq(3)
  end

  it "gives up after the attempt limit and re-raises" do
    calls = 0

    expect do
      described_class.call(context: "test") do
        calls += 1
        raise Errno::ECONNREFUSED
      end
    end.to raise_error(Errno::ECONNREFUSED)

    expect(calls).to eq(described_class::ATTEMPTS)
  end

  # ECONNRESET and ReadTimeout can fire AFTER the ESP accepted the payload, so retrying
  # them would send the same recipients twice. They must reach the caller untouched.
  it "does not retry an error that can follow an accepted payload" do
    [Errno::ECONNRESET, Net::ReadTimeout].each do |error_class|
      calls = 0

      expect do
        described_class.call(context: "test") do
          calls += 1
          raise error_class
        end
      end.to raise_error(error_class)

      expect(calls).to eq(1)
    end
  end

  it "does not retry an error the provider will raise again" do
    calls = 0

    expect do
      described_class.call(context: "test") do
        calls += 1
        raise StandardError, "422 invalid payload"
      end
    end.to raise_error(StandardError, "422 invalid payload")

    expect(calls).to eq(1)
  end

  it "backs off between attempts" do
    expect(described_class).to receive(:sleep).with(2).ordered
    expect(described_class).to receive(:sleep).with(8).ordered
    expect(described_class).to receive(:sleep).with(30).ordered

    expect do
      described_class.call(context: "test") { raise Net::OpenTimeout }
    end.to raise_error(Net::OpenTimeout)
  end
end
