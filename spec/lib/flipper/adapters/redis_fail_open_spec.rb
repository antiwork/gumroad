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

      it "raises the original error for unread gates" do
        error = error_class.new("flag read timed out")
        allow(inner).to receive(:get).and_raise(error)

        expect { feature.enabled? }.to raise_error { |raised| expect(raised).to equal(error) }
      end

      it "returns cached disabled gates on a failed get" do
        expect(feature.enabled?).to be(false)
        allow(inner).to receive(:get).and_raise(error_class)

        expect(feature.enabled?).to be(false)
      end

      it "returns cached gates on a failed get_multi" do
        feature.enable
        cached = adapter.get_multi([feature])
        allow(inner).to receive(:get_multi).and_raise(error_class)

        expect(adapter.get_multi([feature])).to eq(cached)
        allow(inner).to receive(:get).and_raise(error_class)
        expect(feature.enabled?).to be(true)
      end

      it "raises when a failed get_multi includes unread gates" do
        feature.enable
        adapter.get(feature)
        allow(inner).to receive(:get_multi).and_raise(error_class)

        expect { adapter.get_multi([feature, flipper[:unknown]]) }.to raise_error(error_class)
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

      it "raises before the first successful bulk read" do
        allow(inner).to receive(:get_all).and_raise(error_class)
        allow(inner).to receive(:features).and_raise(error_class)

        expect { adapter.get_all }.to raise_error(error_class)
        expect { adapter.features }.to raise_error(error_class)
      end

      it "returns a cached empty feature catalog" do
        expect(adapter.get_all).to eq({})
        allow(inner).to receive(:get_all).and_raise(error_class)
        allow(inner).to receive(:features).and_raise(error_class)

        expect(adapter.get_all).to eq({})
        expect(adapter.features).to eq(Set.new)
      end

      it "raises when the catalog contains unread gates" do
        feature.enable
        adapter.features
        allow(inner).to receive(:get_all).and_raise(error_class)

        expect { adapter.get_all }.to raise_error(error_class)
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
    feature.enable
    flipper[:other].enable
    adapter.get_all
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0)
    expect(ErrorNotifier).to receive(:notify).once

    3.times { feature.enabled? }
    flipper[:other].enabled?
    adapter.get_all
  end

  it "reports again after the reporting interval" do
    feature.enabled?
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

  it "still returns cached gates if error reporting fails" do
    feature.enable
    feature.enabled?
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    allow(ErrorNotifier).to receive(:notify).and_raise(StandardError)

    expect(feature.enabled?).to be(true)
  end

  it "preserves the read error for unread gates if reporting fails" do
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    allow(ErrorNotifier).to receive(:notify).and_raise(StandardError)

    expect { feature.enabled? }.to raise_error(Redis::TimeoutError)
  end

  it "shares fallback values and reporting across adapters in different threads" do
    state = described_class::State.new
    first = described_class.new(inner, state:)
    second = described_class.new(inner, state:)
    feature.enable
    first.get(feature)
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)
    expect(ErrorNotifier).to receive(:notify).once

    results = [first, second].map { |reader| Thread.new { Flipper.new(reader).enabled?(feature.key) } }.map(&:value)
    expect(results).to eq([true, true])
  end

  it "raises for evicted gates while retaining the remaining cached gates" do
    stub_const("#{described_class}::MAX_FEATURES", 2)
    %i[first second third].each { |key| flipper[key].enable }
    adapter.get_all
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    expect { flipper[:first].enabled? }.to raise_error(Redis::TimeoutError)
    expect(flipper[:third].enabled?).to be(true)
  end

  it "does not resurrect gates after a successful disable followed by a read failure" do
    feature.enable
    feature.enabled?
    feature.disable
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    expect { feature.enabled? }.to raise_error(Redis::TimeoutError)
  end

  it "forgets removed features after a successful bulk refresh" do
    feature.enable
    adapter.get_all
    inner.remove(feature)
    expect(adapter.get_all).to eq({})
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    expect { feature.enabled? }.to raise_error(Redis::TimeoutError)
  end

  %i[get get_multi get_all].each do |operation|
    it "does not cache an in-flight #{operation} after a concurrent disable" do
      feature.enable
      started = Queue.new
      resume = Queue.new
      allow(inner).to receive(operation).and_wrap_original do |method, *args|
        result = method.call(*args)
        started << true
        resume.pop
        result
      end
      args = operation == :get_all ? [] : [operation == :get ? feature : [feature]]
      reader = Thread.new { adapter.public_send(operation, *args) }
      expect(started.pop(timeout: 5)).to be(true)
      feature.disable
      resume << true
      reader.value
      allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

      expect { feature.enabled? }.to raise_error(Redis::TimeoutError)
    ensure
      resume << true
      reader&.join(5)
    end
  end

  it "invalidates a read completed while a write was in flight" do
    feature.enable
    allow(inner).to receive(:disable).and_wrap_original do |method, *args|
      expect(feature.enabled?).to be(true)
      method.call(*args)
    end
    feature.disable
    allow(inner).to receive(:get).and_raise(Redis::TimeoutError)

    expect { feature.enabled? }.to raise_error(Redis::TimeoutError)
  end

  it "raises when a bulk snapshot exceeds the cache limit" do
    stub_const("#{described_class}::MAX_FEATURES", 2)
    %i[first second third].each { |key| flipper[key].enable }
    adapter.get_all
    allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)
    allow(inner).to receive(:features).and_raise(Redis::TimeoutError)

    expect { adapter.get_all }.to raise_error(Redis::TimeoutError)
    expect { adapter.features }.to raise_error(Redis::TimeoutError)
  end

  it "raises when a feature catalog exceeds the cache limit" do
    stub_const("#{described_class}::MAX_FEATURES", 2)
    %i[first second third].each { |key| flipper[key].enable }
    adapter.features
    allow(inner).to receive(:features).and_raise(Redis::TimeoutError)

    expect { adapter.features }.to raise_error(Redis::TimeoutError)
  end

  it "does not use individual reads as a complete feature catalog" do
    feature.enable
    adapter.get(feature)
    allow(inner).to receive(:features).and_raise(Redis::TimeoutError)
    allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)

    expect { adapter.features }.to raise_error(Redis::TimeoutError)
    expect { adapter.get_all }.to raise_error(Redis::TimeoutError)
  end

  it "does not preload a catalog after its gates are evicted" do
    stub_const("#{described_class}::MAX_FEATURES", 2)
    feature.enable
    adapter.get_all
    %i[other unknown].each { |key| adapter.get(flipper[key]) }
    allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)

    expect { flipper.preload_all }.to raise_error(Redis::TimeoutError)
  end

  %i[get get_multi].each do |operation|
    it "invalidates the catalog when #{operation} reads an unlisted feature" do
      adapter.get_all
      Flipper.new(inner).enable(feature.key)
      adapter.public_send(operation, operation == :get ? feature : [feature])
      allow(inner).to receive(:get_all).and_raise(Redis::TimeoutError)

      expect { flipper.preload_all }.to raise_error(Redis::TimeoutError)
    end
  end

  it "does not catch non-Redis errors" do
    allow(inner).to receive(:get).and_raise(ArgumentError)

    expect { feature.enabled? }.to raise_error(ArgumentError)
  end
end
