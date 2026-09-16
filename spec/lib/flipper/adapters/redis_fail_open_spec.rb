# frozen_string_literal: true

RSpec.describe Flipper::Adapters::RedisFailOpen do
  let(:inner) { Flipper::Adapters::Memory.new }
  let(:adapter) { described_class.new(inner) }
  let(:flipper) { Flipper.new(adapter) }
  let(:feature) { flipper[:outage_test] }

  before { allow(ErrorNotifier).to receive(:notify) }

  [RedisClient::ReadTimeoutError, Redis::TimeoutError].each do |error_class|
    context "with #{error_class}" do
      it "returns the last-known gates on a failed get" do
        feature.enable
        expect(feature.enabled?).to be(true)
        allow(inner).to receive(:get).and_raise(error_class)

        expect(feature.enabled?).to be(true)
      end

      it "defaults unread gates to off" do
        allow(inner).to receive(:get).and_raise(error_class)

        expect(feature.enabled?).to be(false)
      end

      it "returns cached and default gates on a failed get_multi" do
        feature.enable
        cached = adapter.get_multi([feature])
        allow(inner).to receive(:get_multi).and_raise(error_class)

        expect(adapter.get_multi([feature, flipper[:unknown]])).to eq(
          cached.merge("unknown" => adapter.default_config)
        )
        allow(inner).to receive(:get).and_raise(error_class)
        expect(feature.enabled?).to be(true)
      end

      it "returns the last-known snapshot on a failed get_all" do
        feature.enable
        cached = adapter.get_all
        allow(inner).to receive(:get_all).and_raise(error_class)

        expect(adapter.get_all).to eq(cached)
        allow(inner).to receive(:get).and_raise(error_class)
        expect(feature.enabled?).to be(true)
      end

      it "returns the last-known feature names on a failed features read" do
        feature.enable
        expect(adapter.features).to eq(Set[feature.key])
        allow(inner).to receive(:features).and_raise(error_class)

        expect(adapter.features).to eq(Set[feature.key])
      end

      it "returns empty collections before the first successful bulk read" do
        allow(inner).to receive(:get_all).and_raise(error_class)
        allow(inner).to receive(:features).and_raise(error_class)

        expect(adapter.get_all).to eq({})
        expect(adapter.features).to eq(Set.new)
      end

      %i[add remove clear enable disable].each do |operation|
        it "raises on a failed #{operation}" do
          allow(inner).to receive(operation).and_raise(error_class)
          args = %i[enable disable].include?(operation) ? [feature, feature.gate(:boolean), Flipper::Types::Boolean.new] : [feature]

          expect { adapter.public_send(operation, *args) }.to raise_error(error_class)
        end
      end
    end
  end

  it "reports once per minute across features and read methods" do
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0)
    expect(ErrorNotifier).to receive(:notify).once

    3.times { feature.enabled? }
    flipper[:other].enabled?
    adapter.get_all
  end

  it "reports again after the reporting interval" do
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 159.0, 160.0)
    expect(ErrorNotifier).to receive(:notify).twice

    3.times { feature.enabled? }
  end

  it "refreshes cached gates after Redis recovers" do
    feature.enable
    feature.enabled?
    inner.disable(feature, feature.gate(:boolean), Flipper::Types::Boolean.new)
    expect(feature.enabled?).to be(false)
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    expect(feature.enabled?).to be(false)
  end

  it "does not let callers mutate cached gates" do
    feature.enable_actor(Flipper::Actor.new("User;1"))
    adapter.get(feature)[:actors].clear
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    adapter.get(feature)[:actors].clear
    expect(adapter.get(feature)[:actors]).to eq(Set["User;1"])
  end

  it "does not catch non-Redis errors" do
    allow(inner).to receive(:get).and_raise(ArgumentError)

    expect { feature.enabled? }.to raise_error(ArgumentError)
  end
end
