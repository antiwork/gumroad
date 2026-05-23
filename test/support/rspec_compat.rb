# frozen_string_literal: true

require "ostruct"
require "stringio"

module RspecCompat
  class AssertionNotMet < Minitest::Assertion; end

  class << self
    def shared_examples
      @shared_examples ||= {}
    end

    def normalize_metadata(args, kwargs = {})
      args.each_with_object(kwargs.dup) do |arg, metadata|
        case arg
        when Symbol
          metadata[arg] = true
        when Hash
          metadata.merge!(arg)
        end
      end
    end

    def value_matches?(expected, actual)
      case expected
      when ArgumentMatcher
        expected.matches?(actual)
      when Hash
        return false unless actual.respond_to?(:[])

        expected.all? { |key, value| value_matches?(value, actual[key] || actual[key.to_s]) }
      when Array
        actual.is_a?(Array) &&
          expected.length == actual.length &&
          expected.zip(actual).all? { |expected_item, actual_item| value_matches?(expected_item, actual_item) }
      else
        expected == actual
      end
    end
  end

  class ExampleProxy
    def initialize(callback)
      @callback = callback
    end

    def run
      @callback.call
    end
  end

  class ArgumentMatcher
    def matches?(_actual)
      true
    end
  end

  class AnythingMatcher < ArgumentMatcher; end
  class AnyArgsMatcher < ArgumentMatcher; end

  class BooleanMatcher < ArgumentMatcher
    def matches?(actual)
      actual == true || actual == false
    end
  end

  class KindOfMatcher < ArgumentMatcher
    def initialize(klass)
      @klass = klass
    end

    def matches?(actual)
      actual.is_a?(@klass)
    end
  end

  class InstanceOfMatcher < ArgumentMatcher
    def initialize(klass)
      @klass = klass
    end

    def matches?(actual)
      actual.instance_of?(@klass)
    end
  end

  class HashIncludingMatcher < ArgumentMatcher
    def initialize(*expected)
      @expected_pairs = expected.select { |value| value.is_a?(Hash) }.reduce({}) { |pairs, hash| pairs.merge(hash) }
      @expected_keys = expected.reject { |value| value.is_a?(Hash) }
    end

    def matches?(actual)
      return false unless actual.is_a?(Hash)

      @expected_keys.all? { |key| actual.key?(key) || actual.key?(key.to_s) } &&
        @expected_pairs.all? { |key, value| RspecCompat.value_matches?(value, value_for(actual, key)) }
    end

    private
      def value_for(actual, key)
        return actual[key] if actual.key?(key)
        actual[key.to_s]
      end
  end

  class HashExcludingMatcher < ArgumentMatcher
    def initialize(*expected)
      @expected_keys = expected.flat_map { |value| value.is_a?(Hash) ? value.keys : value }
    end

    def matches?(actual)
      actual.is_a?(Hash) && @expected_keys.none? { |key| actual.key?(key) || actual.key?(key.to_s) }
    end
  end

  class ArrayIncludingMatcher < ArgumentMatcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      actual.is_a?(Array) && @expected.all? { |expected| actual.any? { |item| RspecCompat.value_matches?(expected, item) } }
    end
  end

  class Matcher
    def and(other)
      CompoundMatcher.new(self, other)
    end

    def or(other)
      OrMatcher.new(self, other)
    end

    def assert(test, actual, negated: false)
      matched = matches?(actual, test)
      matched = !matched if negated
      test.assert matched, failure_message(actual, negated)
    end

    def failure_message(actual, negated)
      expectation = negated ? "not to match" : "to match"
      "expected #{actual.inspect} #{expectation} #{self.class.name}"
    end
  end

  class PredicateMatcher < Matcher
    def initialize(name, *args)
      @name = name
      @args = args
    end

    def matches?(actual, _test)
      if actual.respond_to?("#{@name}?")
        actual.public_send("#{@name}?", *@args)
      else
        actual.public_send(@name, *@args)
      end
    end
  end

  class EqMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      RspecCompat.value_matches?(@expected, actual)
    end

    def failure_message(actual, negated)
      negated ? "expected #{actual.inspect} not to equal #{@expected.inspect}" : "expected #{@expected.inspect}, got #{actual.inspect}"
    end
  end

  class IdentityMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.equal?(@expected)
    end
  end

  class NilMatcher < Matcher
    def matches?(actual, _test)
      actual.nil?
    end
  end

  class TruthyMatcher < Matcher
    def matches?(actual, _test)
      !!actual
    end
  end

  class FalseyMatcher < Matcher
    def matches?(actual, _test)
      !actual
    end
  end

  class EmptyMatcher < Matcher
    def matches?(actual, _test)
      actual.empty?
    end
  end

  class IncludeMatcher < Matcher
    def initialize(*expected)
      @expected = expected
    end

    def matches?(actual, _test)
      @expected.all? do |expected|
        if actual.is_a?(Hash) && expected.is_a?(Hash)
          expected.all? { |key, value| RspecCompat.value_matches?(value, actual[key] || actual[key.to_s]) }
        else
          actual.include?(expected)
        end
      end
    end
  end

  class MatchMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      @expected === actual || actual.to_s.match?(@expected)
    end
  end

  class CollectionMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.to_a.size == @expected.to_a.size && (@expected.to_a - actual.to_a).empty? && (actual.to_a - @expected.to_a).empty?
    end
  end

  class HaveAttributesMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      @expected.all? { |name, value| RspecCompat.value_matches?(value, actual.public_send(name)) }
    end
  end

  class HaveKeyMatcher < Matcher
    def initialize(key)
      @key = key
    end

    def matches?(actual, _test)
      actual.key?(@key)
    end
  end

  class StartWithMatcher < Matcher
    def initialize(*expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.respond_to?(:start_with?) ? actual.start_with?(*@expected) : actual.to_a.first(@expected.length) == @expected
    end
  end

  class EndWithMatcher < Matcher
    def initialize(*expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.respond_to?(:end_with?) ? actual.end_with?(*@expected) : actual.to_a.last(@expected.length) == @expected
    end
  end

  class RespondToMatcher < Matcher
    def initialize(method_name)
      @method_name = method_name
    end

    def matches?(actual, _test)
      actual.respond_to?(@method_name)
    end
  end

  class SatisfyMatcher < Matcher
    def initialize(block)
      @block = block
    end

    def matches?(actual, _test)
      @block.call(actual)
    end
  end

  class AllMatcher < Matcher
    def initialize(matcher)
      @matcher = matcher
    end

    def matches?(actual, test)
      actual.all? { |item| @matcher.matches?(item, test) }
    end
  end

  class ComparatorBuilder < Matcher
    def initialize(expected = :__none__)
      @expected = expected
    end

    def matches?(actual, _test)
      return actual.equal?(@expected) unless @expected == :__none__

      !!actual
    end

    def >(other)
      ComparisonMatcher.new(:>, other)
    end

    def >=(other)
      ComparisonMatcher.new(:>=, other)
    end

    def <(other)
      ComparisonMatcher.new(:<, other)
    end

    def <=(other)
      ComparisonMatcher.new(:<=, other)
    end
  end

  class ComparisonMatcher < Matcher
    def initialize(operator, expected)
      @operator = operator
      @expected = expected
    end

    def matches?(actual, _test)
      actual.public_send(@operator, @expected)
    end
  end

  class TypeMatcher < Matcher
    def initialize(klass, exact: false)
      @klass = klass
      @exact = exact
    end

    def matches?(actual, _test)
      @exact ? actual.instance_of?(@klass) : actual.is_a?(@klass)
    end
  end

  class WithinMatcher < Matcher
    def initialize(delta)
      @delta = delta
    end

    def of(expected)
      @expected = expected
      self
    end

    def matches?(actual, _test)
      (actual - @expected).abs <= @delta
    end
  end

  class BetweenMatcher < Matcher
    def initialize(min, max)
      @min = min
      @max = max
      @exclusive = false
    end

    def inclusive
      @exclusive = false
      self
    end

    def exclusive
      @exclusive = true
      self
    end

    def matches?(actual, _test)
      @exclusive ? actual > @min && actual < @max : actual >= @min && actual <= @max
    end
  end

  class InMatcher < Matcher
    def initialize(collection)
      @collection = collection
    end

    def matches?(actual, _test)
      @collection.include?(actual)
    end
  end

  class HttpStatusMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      expected_status = @expected.is_a?(Symbol) ? Rack::Utils.status_code(@expected) : @expected
      actual.respond_to?(:status) && actual.status == expected_status
    end
  end

  class RedirectMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, test)
      if test.respond_to?(:assert_redirected_to)
        test.assert_redirected_to @expected
        true
      elsif actual.respond_to?(:location)
        actual.location == @expected
      else
        false
      end
    rescue Minitest::Assertion
      false
    end
  end

  class ResponsePredicateMatcher < Matcher
    def initialize(predicate)
      @predicate = predicate
    end

    def matches?(actual, _test)
      actual.respond_to?(@predicate) && actual.public_send(@predicate)
    end
  end

  class RenderTemplateMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(_actual, test)
      return false unless test.respond_to?(:assert_template)

      test.assert_template @expected
      true
    rescue Minitest::Assertion
      false
    end
  end

  class PermitMatcher < Matcher
    def initialize(*args)
      @args = args
    end

    def matches?(actual, test)
      action = test.rspec_metadata[:permission_action]
      return false unless action

      policy = actual.is_a?(Class) ? actual.new(*@args) : actual
      policy.public_send(action)
    end
  end

  class SidekiqJobMatcher < Matcher
    def initialize(*args)
      @args = args
      @queue = nil
      @time = nil
      @immediate = false
    end

    def with(*args)
      @args = args
      self
    end

    def on(queue)
      @queue = queue
      self
    end

    def at(time)
      @time = time
      self
    end

    def in(duration)
      @time = Time.current + duration
      self
    end

    def immediately
      @immediate = true
      self
    end

    def matches?(actual, _test)
      return false unless actual.respond_to?(:jobs)

      actual.jobs.any? do |job|
        args_match = @args.empty? || RspecCompat.value_matches?(@args, job["args"])
        queue_match = @queue.nil? || job["queue"] == @queue
        time_match = @time.nil? || (job["at"] && (Time.zone.at(job["at"]) - @time).abs < 2)
        immediate_match = !@immediate || !job.key?("at")
        args_match && queue_match && time_match && immediate_match
      end
    end
  end

  class JsonSchemaMatcher < Matcher
    def initialize(name)
      @name = name
    end

    def matches?(actual, _test)
      schema_path = Rails.root.join("test", "support", "schemas", "#{@name}.json")
      JSON::Validator.validate!(schema_path.to_s, actual)
      true
    rescue JSON::Schema::ValidationError
      false
    end
  end

  class InertiaComponentMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.respond_to?(:component) && actual.component == @expected
    end
  end

  class InertiaPropsMatcher < Matcher
    def initialize(expected, exact:)
      @expected = expected
      @exact = exact
    end

    def matches?(actual, _test)
      return false unless actual.respond_to?(:props)

      @exact ? actual.props == @expected : actual.props.to_h.deep_stringify_keys.merge(@expected.deep_stringify_keys) == actual.props.to_h.deep_stringify_keys
    end
  end

  class IndifferentAccessMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual, _test)
      actual.with_indifferent_access == @expected.with_indifferent_access
    end
  end

  class HtmlMatcher < Matcher
    def initialize(expected, **options)
      @expected = expected
      @options = options
    end

    def matches?(actual, _test)
      expected_doc = Nokogiri::HTML5.fragment(@expected)
      actual_doc = Nokogiri::HTML5.fragment(actual)
      normalize_html(expected_doc) == normalize_html(actual_doc)
    end

    private
      def normalize_html(node)
        node.to_html.gsub(/\s+/, " ").strip
      end
  end

  class BrowserLikeMatcher < Matcher
    def initialize(name, *args, **kwargs)
      @name = name
      @args = args
      @kwargs = kwargs
    end

    def matches?(actual, _test)
      method_name = :"has_#{@name}?"
      return actual.public_send(method_name, *@args, **@kwargs) if actual.respond_to?(method_name)

      case @name
      when :content, :text
        actual.to_s.include?(@args.first.to_s)
      when :no_content, :no_text
        !actual.to_s.include?(@args.first.to_s)
      else
        false
      end
    end
  end

  class StreamMatcher < Matcher
    def initialize(stream)
      @stream = stream
    end

    def matches?(actual, test)
      return actual.streams.include?(@stream) if actual.respond_to?(:streams)
      return test.assert_has_stream(@stream) || true if test.respond_to?(:assert_has_stream)

      false
    rescue Minitest::Assertion
      false
    end
  end

  class RejectedConnectionMatcher < Matcher
    def block_matches?(block, _test, negated:)
      block.call
      negated
    rescue ActionCable::Connection::Authorization::UnauthorizedError
      !negated
    end
  end

  class CompoundMatcher < Matcher
    attr_reader :matchers

    def initialize(*matchers)
      @matchers = matchers.flat_map { |matcher| matcher.is_a?(CompoundMatcher) ? matcher.matchers : matcher }
    end

    def matches?(actual, test)
      @matchers.all? { |matcher| matcher.matches?(actual, test) }
    end

    def block_matches?(block, test, negated:)
      before_values = @matchers.map { |matcher| matcher.capture_before(test) }
      block.call
      @matchers.zip(before_values).all? { |matcher, before| matcher.matches_after?(before, test, negated:) }
    end
  end

  class OrMatcher < Matcher
    def initialize(left, right)
      @left = left
      @right = right
    end

    def matches?(actual, test)
      @left.matches?(actual, test) || @right.matches?(actual, test)
    end
  end

  class ChangeMatcher < Matcher
    def initialize(receiver = nil, message = nil, &block)
      @value_block = block || -> { receiver.public_send(message) }
      @expected_delta = :__unset__
      @expected_from = :__unset__
      @expected_to = :__unset__
    end

    def by(delta)
      @expected_delta = delta
      self
    end

    def from(value)
      @expected_from = value
      self
    end

    def to(value)
      @expected_to = value
      self
    end

    def capture_before(test)
      test.instance_exec(&@value_block)
    end

    def matches_after?(before, test, negated:)
      after = test.instance_exec(&@value_block)
      changed = before != after
      matched = if @expected_delta != :__unset__
        after - before == @expected_delta
      elsif @expected_from != :__unset__ || @expected_to != :__unset__
        (@expected_from == :__unset__ || before == @expected_from) && (@expected_to == :__unset__ || after == @expected_to)
      else
        changed
      end
      negated ? !changed : matched
    end
  end

  class RaiseErrorMatcher < Matcher
    def initialize(expected = StandardError, message = nil)
      @expected = expected
      @message = message
    end

    def block_matches?(block, _test, negated:)
      block.call
      negated
    rescue Exception => e
      return false if negated
      return e.message.match?(@expected) if @expected.is_a?(Regexp)

      class_match = @expected.nil? || e.is_a?(@expected)
      message_match = @message.nil? || (@message.is_a?(Regexp) ? e.message.match?(@message) : e.message == @message)
      class_match && message_match
    end
  end

  class OutputMatcher < Matcher
    def initialize(expected)
      @expected = expected
      @stream = :stdout
    end

    def to_stdout
      @stream = :stdout
      self
    end

    def to_stderr
      @stream = :stderr
      self
    end

    def block_matches?(block, _test, negated:)
      io = StringIO.new
      stream = @stream == :stdout ? $stdout : $stderr
      if @stream == :stdout
        $stdout = io
      else
        $stderr = io
      end
      block.call
      matched = @expected.is_a?(Regexp) ? io.string.match?(@expected) : io.string == @expected.to_s
      negated ? !matched : matched
    ensure
      if @stream == :stdout
        $stdout = stream
      else
        $stderr = stream
      end
    end
  end

  class ExpectationTarget
    def initialize(test, actual)
      @test = test
      @actual = actual
    end

    def to(matcher = nil, *args)
      assert_matcher(matcher, args, negated: false)
    end

    def not_to(matcher = nil, *args)
      assert_matcher(matcher, args, negated: true)
    end

    alias_method :to_not, :not_to

    private
      def assert_matcher(matcher, args, negated:)
        matcher ||= EqMatcher.new(args.first)
        if matcher.respond_to?(:install_on)
          matcher.expectation = true if matcher.respond_to?(:expectation=)
          return matcher.install_on(@actual, @test, negated:)
        end
        if matcher.is_a?(Matcher)
          matcher.assert(@test, @actual, negated:)
        elsif matcher.respond_to?(:matches?)
          matched = matcher.matches?(@actual)
          matched = !matched if negated
          @test.assert matched, matcher_failure_message(matcher, negated)
        else
          @test.assert negated ? @actual != matcher : @actual == matcher
        end
        matcher
      end

      def matcher_failure_message(matcher, negated)
        if negated && matcher.respond_to?(:failure_message_when_negated)
          matcher.failure_message_when_negated
        elsif matcher.respond_to?(:failure_message)
          matcher.failure_message
        else
          "expectation failed"
        end
      end
  end

  class BlockExpectationTarget
    def initialize(test, block)
      @test = test
      @block = block
    end

    def to(matcher)
      assert_block_matcher(matcher, negated: false)
    end

    def not_to(matcher)
      assert_block_matcher(matcher, negated: true)
    end

    alias_method :to_not, :not_to

    private
      def assert_block_matcher(matcher, negated:)
        matched = if matcher.respond_to?(:block_matches?)
          matcher.block_matches?(@block, @test, negated:)
        elsif matcher.is_a?(ChangeMatcher)
          before = matcher.capture_before(@test)
          @block.call
          matcher.matches_after?(before, @test, negated:)
        else
          false
        end
        @test.assert matched, "block expectation failed"
        matcher
      end
  end

  class MethodStub
    attr_reader :method_name, :calls

    def initialize(method_name, expectation: false, any_instance: false, negated: false)
      @method_name = method_name
      @expectation = expectation
      @any_instance = any_instance
      @negated = negated
      @expected_args = nil
      @return_values = [nil]
      @raise_error = nil
      @call_original = false
      @wrap_original = nil
      @calls = []
    end

    def with(*args, **kwargs)
      @expected_args = kwargs.empty? ? args : args + [kwargs]
      self
    end

    def and_return(*values)
      @return_values = values.empty? ? [nil] : values
      self
    end

    def and_raise(error, message = nil)
      @raise_error = [error, message]
      self
    end

    def and_call_original
      @call_original = true
      self
    end

    def and_wrap_original(&block)
      @wrap_original = block
      self
    end

    def and_yield(*values)
      @yield_values = values
      self
    end

    def once = self
    def twice = self
    def times = self
    def ordered = self
    def exactly(_count) = self
    def at_least(_count) = self
    def at_most(_count) = self
    def never
      @negated = true
      self
    end

    def matches_args?(args)
      return true if @expected_args&.any? { |arg| arg.is_a?(AnyArgsMatcher) }

      @expected_args.nil? || RspecCompat.value_matches?(@expected_args, args)
    end

    def call(original, receiver, args, block)
      @calls << args
      raise AssertionNotMet, "unexpected arguments for #{@method_name}: #{args.inspect}" unless matches_args?(args)
      raise build_error if @raise_error
      block.call(*@yield_values) if @yield_values && block
      return @wrap_original.call(original, *args, &block) if @wrap_original
      return original.call(*args, &block) if @call_original && original

      @return_values.length > 1 ? @return_values.shift : @return_values.first
    end

    def verify!
      return unless @expectation

      if @negated
        raise AssertionNotMet, "expected #{@method_name} not to be called" unless @calls.empty?
      else
        raise AssertionNotMet, "expected #{@method_name} to be called" if @calls.empty?
      end
    end

    private
      def build_error
        error, message = @raise_error
        return error if error.is_a?(Exception)
        return error.new(message) if message

        error.new
      end
  end

  class ReceiveMatcher
    attr_writer :expectation

    def initialize(method_name, expectation: false, any_instance: false)
      @method_name = method_name
      @expectation = expectation
      @any_instance = any_instance
    end

    def install_on(target, test, negated:)
      @stub = MethodStub.new(@method_name, expectation: @expectation, any_instance: @any_instance)
      @stub.instance_variable_set(:@negated, negated)
      test.__send__(@any_instance ? :install_any_instance_stub : :install_stub, target, @stub)
      @stub
    end
  end

  class HaveReceivedMatcher < Matcher
    def initialize(method_name)
      @method_name = method_name
      @expected_args = nil
    end

    def with(*args, **kwargs)
      @expected_args = kwargs.empty? ? args : args + [kwargs]
      self
    end

    def matches?(actual, _test)
      calls = actual.__rspec_compat_calls__[@method_name] || []
      return calls.any? if @expected_args.nil?

      calls.any? { |args| RspecCompat.value_matches?(@expected_args, args) }
    end
  end

  class StubBuilder
    def initialize(test, target, expectation:, any_instance: false)
      @test = test
      @target = target
      @expectation = expectation
      @any_instance = any_instance
    end

    def to(matcher)
      matcher.expectation = @expectation if matcher.respond_to?(:expectation=)
      matcher.install_on(@target, @test, negated: false)
    end

    def not_to(matcher)
      matcher.expectation = @expectation if matcher.respond_to?(:expectation=)
      matcher.install_on(@target, @test, negated: true)
    end

    alias_method :to_not, :not_to

    def receive(method_name)
      ReceiveMatcher.new(method_name, expectation: @expectation, any_instance: @any_instance)
    end
  end

  class TestDouble
    attr_reader :__rspec_compat_calls__

    def initialize(methods = {})
      @__rspec_compat_calls__ = Hash.new { |hash, key| hash[key] = [] }
      methods.each do |name, value|
        define_singleton_method(name) do |*args, **kwargs|
          call_args = kwargs.empty? ? args : args + [kwargs]
          @__rspec_compat_calls__[name] << call_args
          value
        end
      end
    end

    def as_null_object
      @null_object = true
      self
    end

    def method_missing(name, *args, **kwargs, &block)
      call_args = kwargs.empty? ? args : args + [kwargs]
      @__rspec_compat_calls__[name] << call_args
      return self if @null_object

      super
    end

    def respond_to_missing?(_name, _include_private = false)
      @null_object || super
    end
  end

  module InstanceMethods
    def run
      metadata = rspec_metadata
      Thread.current[:_rspec_example_metadata] = metadata
      chain = -> { run_without_rspec_compat }
      self.class.rspec_around_hooks.reverse_each do |hook|
        inner = chain
        chain = -> { instance_exec(ExampleProxy.new(inner), &hook) }
      end
      if defined?(Link) && !metadata[:enforce_product_creation_limit]
        inner = chain
        chain = -> { Link.bypass_product_creation_limit { inner.call } }
      end
      if defined?(Sidekiq::Testing)
        inner = chain
        chain = -> { metadata[:sidekiq_inline] ? Sidekiq::Testing.inline! { inner.call } : Sidekiq::Testing.fake! { inner.call } }
      end
      if metadata[:freeze_time] && respond_to?(:freeze_time)
        inner = chain
        chain = -> { freeze_time { inner.call } }
      end
      if metadata[:vcr] && defined?(VCR)
        inner = chain
        cassette_name = "#{self.class.name}/#{name}".underscore
        chain = -> { VCR.use_cassette(cassette_name, allow_playback_repeats: true) { inner.call } }
      end
      chain.call
    ensure
      Thread.current[:_rspec_example_metadata] = nil
    end

    def expect(actual = :__no_actual__, &block)
      block ? BlockExpectationTarget.new(self, block) : ExpectationTarget.new(self, actual)
    end

    def is_expected
      expect(subject)
    end

    def allow(target)
      StubBuilder.new(self, target, expectation: false)
    end

    def expect_any_instance_of(target)
      StubBuilder.new(self, target, expectation: true, any_instance: true)
    end

    def allow_any_instance_of(target)
      StubBuilder.new(self, target, expectation: false, any_instance: true)
    end

    def receive(method_name)
      ReceiveMatcher.new(method_name)
    end

    def receive_message_chain(*names)
      ReceiveMessageChainMatcher.new(names)
    end

    def have_received(method_name)
      HaveReceivedMatcher.new(method_name)
    end

    def double(*args, **kwargs)
      methods = args.last.is_a?(Hash) ? args.last : kwargs
      TestDouble.new(methods)
    end

    alias_method :spy, :double
    alias_method :instance_double, :double
    alias_method :class_double, :double

    def described_class
      self.class.described_class
    end

    def subject
      @__rspec_subject ||= if self.class.rspec_subject_block
        instance_exec(&self.class.rspec_subject_block)
      elsif described_class.is_a?(Class)
        described_class.new
      else
        described_class
      end
    end

    def install_stub(target, stub)
      singleton = class << target; self; end
      unless target.respond_to?(:__rspec_compat_calls__)
        target.define_singleton_method(:__rspec_compat_calls__) do
          @__rspec_compat_calls__ ||= Hash.new { |hash, key| hash[key] = [] }
        end
      end
      original_defined = singleton.method_defined?(stub.method_name) || singleton.private_method_defined?(stub.method_name)
      original = target.method(stub.method_name) if original_defined
      test = self
      target.define_singleton_method(stub.method_name) do |*args, **kwargs, &block|
        call_args = kwargs.empty? ? args : args + [kwargs]
        __rspec_compat_calls__[stub.method_name] << call_args if respond_to?(:__rspec_compat_calls__)
        stub.call(original, self, call_args, block)
      end
      rspec_stub_restores << -> do
        singleton.send(:remove_method, stub.method_name) if singleton.method_defined?(stub.method_name)
        singleton.define_method(stub.method_name, original) if original_defined
      end
      rspec_expectation_stubs << stub
      stub
    end

    def install_any_instance_stub(target, stub)
      original_defined = target.method_defined?(stub.method_name) || target.private_method_defined?(stub.method_name)
      original = target.instance_method(stub.method_name) if original_defined
      target.define_method(stub.method_name) do |*args, **kwargs, &block|
        call_args = kwargs.empty? ? args : args + [kwargs]
        bound_original = original&.bind(self)
        stub.call(bound_original, self, call_args, block)
      end
      rspec_stub_restores << -> do
        target.send(:remove_method, stub.method_name) if target.method_defined?(stub.method_name)
        target.define_method(stub.method_name, original) if original_defined
      end
      rspec_expectation_stubs << stub
      stub
    end

    def rspec_stub_restores
      @rspec_stub_restores ||= []
    end

    def rspec_expectation_stubs
      @rspec_expectation_stubs ||= []
    end

    def rspec_metadata
      self.class.rspec_metadata.merge(self.class.rspec_test_metadata[name] || {})
    end

    def aggregate_failures
      yield
    end

    def pending(message = "pending")
      skip message
    end

    def eq(expected) = EqMatcher.new(expected)
    def eql(expected) = EqMatcher.new(expected)
    def equal(expected) = IdentityMatcher.new(expected)
    def be(expected = :__none__) = ComparatorBuilder.new(expected)
    def be_nil = NilMatcher.new
    def be_truthy = TruthyMatcher.new
    def be_falsey = FalseyMatcher.new
    def be_empty = EmptyMatcher.new
    def be_present = PredicateMatcher.new(:present)
    def be_blank = PredicateMatcher.new(:blank)
    def be_a(klass) = TypeMatcher.new(klass)
    def be_an(klass) = TypeMatcher.new(klass)
    def be_kind_of(klass) = TypeMatcher.new(klass)
    def be_a_kind_of(klass) = TypeMatcher.new(klass)
    def be_instance_of(klass) = TypeMatcher.new(klass, exact: true)
    def be_an_instance_of(klass) = TypeMatcher.new(klass, exact: true)
    def include(*expected) = IncludeMatcher.new(*expected)
    def match(expected) = MatchMatcher.new(expected)
    def match_array(expected) = CollectionMatcher.new(expected)
    def contain_exactly(*expected) = CollectionMatcher.new(expected)
    def have_attributes(expected) = HaveAttributesMatcher.new(expected)
    def have_key(key) = HaveKeyMatcher.new(key)
    def start_with(*expected) = StartWithMatcher.new(*expected)
    def end_with(*expected) = EndWithMatcher.new(*expected)
    def respond_to(method_name) = RespondToMatcher.new(method_name)
    def satisfy(&block) = SatisfyMatcher.new(block)
    def all(matcher) = AllMatcher.new(matcher)
    def be_within(delta) = WithinMatcher.new(delta)
    def be_between(min, max) = BetweenMatcher.new(min, max)
    def be_in(collection) = InMatcher.new(collection)
    def have_http_status(expected) = HttpStatusMatcher.new(expected)
    def redirect_to(expected) = RedirectMatcher.new(expected)
    def be_successful = ResponsePredicateMatcher.new(:successful?)
    def be_redirect = ResponsePredicateMatcher.new(:redirect?)
    def render_template(expected) = RenderTemplateMatcher.new(expected)
    def permit(*args) = PermitMatcher.new(*args)
    def have_enqueued_sidekiq_job(*args) = SidekiqJobMatcher.new(*args)
    def have_stream_from(stream) = StreamMatcher.new(stream)
    def have_rejected_connection = RejectedConnectionMatcher.new
    def match_json_schema(name) = JsonSchemaMatcher.new(name)
    def render_component(name) = InertiaComponentMatcher.new(name)
    def have_exact_props(expected) = InertiaPropsMatcher.new(expected, exact: true)
    def include_props(expected) = InertiaPropsMatcher.new(expected, exact: false)
    def equal_with_indifferent_access(expected) = IndifferentAccessMatcher.new(expected)
    def match_html(expected, **options) = HtmlMatcher.new(expected, **options)
    def change(receiver = nil, message = nil, &block) = ChangeMatcher.new(receiver, message, &block)
    def raise_error(expected = StandardError, message = nil) = RaiseErrorMatcher.new(expected, message)
    def output(expected) = OutputMatcher.new(expected)
    def anything = AnythingMatcher.new
    def any_args = AnyArgsMatcher.new
    def boolean = BooleanMatcher.new
    def kind_of(klass) = KindOfMatcher.new(klass)
    def a_kind_of(klass) = KindOfMatcher.new(klass)
    def an_instance_of(klass) = InstanceOfMatcher.new(klass)
    def instance_of(klass) = InstanceOfMatcher.new(klass)
    def hash_including(*expected) = HashIncludingMatcher.new(*expected)
    def a_hash_including(*expected) = HashIncludingMatcher.new(*expected)
    def hash_excluding(*expected) = HashExcludingMatcher.new(*expected)
    def hash_not_including(*expected) = HashExcludingMatcher.new(*expected)
    def a_hash_excluding(*expected) = HashExcludingMatcher.new(*expected)
    def excluding(*expected) = HashExcludingMatcher.new(*expected)
    def array_including(*expected) = ArrayIncludingMatcher.new(expected)
    def an_array_including(*expected) = ArrayIncludingMatcher.new(expected)
    def a_collection_including(*expected) = ArrayIncludingMatcher.new(expected)

    def method_missing(name, *args, **kwargs, &block)
      name_string = name.to_s
      if name_string.start_with?("be_")
        return PredicateMatcher.new(name_string.delete_prefix("be_"), *args, **kwargs)
      end
      if name_string.start_with?("have_no_")
        return BrowserLikeMatcher.new(:"no_#{name_string.delete_prefix("have_no_")}", *args, **kwargs)
      end
      if name_string.start_with?("have_")
        return BrowserLikeMatcher.new(name_string.delete_prefix("have_").to_sym, *args, **kwargs)
      end

      super
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.start_with?("be_", "have_") || super
    end
  end

  class ReceiveMessageChainMatcher
    attr_writer :expectation

    def initialize(names)
      @names = names
      @expectation = false
    end

    def install_on(target, test, negated:)
      first, *rest = @names
      current = TestDouble.new
      receiver = current
      rest[0...-1].each do |name|
        child = TestDouble.new
        receiver.define_singleton_method(name) { child }
        receiver = child
      end
      matcher = ReceiveMatcher.new(first, expectation: @expectation)
      stub = matcher.install_on(target, test, negated:)
      stub.and_return(current)
      ChainStubProxy.new(receiver, rest.last)
    end
  end

  class ChainStubProxy
    def initialize(receiver, method_name)
      @receiver = receiver
      @method_name = method_name
    end

    def and_return(value)
      @receiver.define_singleton_method(@method_name) { value } if @method_name
      value
    end
  end

  module ClassMethods
    attr_accessor :described_class, :rspec_subject_block

    def inherited(subclass)
      super
      subclass.described_class = described_class
      subclass.rspec_subject_block = rspec_subject_block
      subclass.rspec_metadata = rspec_metadata.dup
    end

    def rspec_metadata
      @rspec_metadata ||= {}
    end

    def rspec_metadata=(metadata)
      @rspec_metadata = metadata
    end

    def rspec_test_metadata
      @rspec_test_metadata ||= {}
    end

    def rspec_around_hooks
      inherited_hooks = superclass.respond_to?(:rspec_around_hooks) ? superclass.rspec_around_hooks : []
      inherited_hooks + own_rspec_around_hooks
    end

    def own_rspec_around_hooks
      @own_rspec_around_hooks ||= []
    end

    def context_(description, *args, **kwargs, &block)
      subclass = Class.new(self)
      subclass.rspec_metadata = rspec_metadata.merge(RspecCompat.normalize_metadata(args, kwargs))
      const_set(unique_context_name(description), subclass)
      subclass.class_eval(&block)
    end

    alias_method :context, :context_
    alias_method :describe, :context_

    def permissions(action, &block)
      context_(action.to_s, permission_action: action, &block)
    end

    def let(name, &block)
      define_method(name) do
        ivar = :"@#{name}"
        return instance_variable_get(ivar) if instance_variable_defined?(ivar)

        instance_variable_set(ivar, instance_exec(&block))
      end
    end

    def let!(name, &block)
      let(name, &block)
      setup { public_send(name) }
    end

    def subject(name = nil, &block)
      self.rspec_subject_block = block
      define_method(name) { subject } if name
    end

    def before(*_args, **_kwargs, &block)
      setup(&block)
    end

    def after(*_args, **_kwargs, &block)
      teardown(&block)
    end

    def around(*_args, **_kwargs, &block)
      own_rspec_around_hooks << block
    end

    def test(name, *args, **kwargs, &block)
      metadata = rspec_metadata.merge(RspecCompat.normalize_metadata(args, kwargs))
      method_name = "test_#{name.to_s.gsub(/\s+/, "_").gsub(/[^A-Za-z0-9_]/, "")}"
      rspec_test_metadata[method_name] = metadata
      minitest_declarative_test(name, &block)
    end

    def it(description = "matches expectation", *args, **kwargs, &block)
      test(description, *args, **kwargs, &block)
    end

    alias_method :specify, :it
    alias_method :scenario, :it

    def xit(description = "skipped example", *args, **kwargs, &block)
      test(description, *args, **kwargs) do
        skip "pending conversion from disabled example"
        instance_exec(&block) if block
      end
    end

    alias_method :xdescribe, :context_
    alias_method :xcontext, :context_

    def shared_examples(name, *args, &block)
      RspecCompat.shared_examples[name] = [block, args]
    end

    alias_method :shared_examples_for, :shared_examples
    alias_method :shared_context, :shared_examples

    def include_examples(name, *args, **kwargs, &customization)
      block, default_args = RspecCompat.shared_examples.fetch(name)
      class_eval(&customization) if customization
      class_exec(*(args.empty? && kwargs.empty? ? default_args : args), **kwargs, &block)
    end

    alias_method :it_behaves_like, :include_examples
    alias_method :include_context, :include_examples

    private
      def unique_context_name(description)
        @context_counter ||= 0
        @context_counter += 1
        base = description.to_s.gsub(/[^A-Za-z0-9]+/, "_").split("_").reject(&:empty?).map(&:capitalize).join
        base = "Context" if base.blank?
        "#{base}#{@context_counter}"
      end
  end
end

module RspecCompatKernel
  def shared_examples(name, *args, &block)
    RspecCompat.shared_examples[name] = [block, args]
  end

  alias_method :shared_examples_for, :shared_examples
  alias_method :shared_context, :shared_examples
end

Object.include RspecCompatKernel

class RspecCompat::TestDouble
  def self.build(*args, **kwargs)
    methods = args.last.is_a?(Hash) ? args.last : kwargs
    new(methods)
  end
end

module RspecCompatInstall
  def self.install!(base)
    return if base < RspecCompat::InstanceMethods

    class << base
      alias_method :minitest_declarative_test, :test unless method_defined?(:minitest_declarative_test)
    end
    base.alias_method :run_without_rspec_compat, :run unless base.method_defined?(:run_without_rspec_compat)
    base.include RspecCompat::InstanceMethods
    base.extend RspecCompat::ClassMethods
  end
end
