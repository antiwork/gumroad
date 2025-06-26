# frozen_string_literal: true

require 'rails_helper'
require 'prop_check'

RSpec.describe TipOptionsService, type: :service do
  include PropCheck::RSpec

  describe 'are_tip_options_valid?', :property_based do
    property 'accepts arrays of integers' do
      forall do
        array_of(integer)
      end.check do |options|
        expect(TipOptionsService.send(:are_tip_options_valid?, options)).to be true
      end
    end

    property 'rejects non-arrays' do
      forall do
        one_of([
          integer,
          string,
          boolean,
          float,
          nil
        ])
      end.check do |non_array|
        next if non_array.is_a?(Array)
        expect(TipOptionsService.send(:are_tip_options_valid?, non_array)).to be false
      end
    end

    property 'rejects arrays with non-integer elements' do
      forall do
        array_of(one_of([string, float, boolean, nil]))
      end.check do |options|
        next if options.empty? || options.all? { |o| o.is_a?(Integer) }
        expect(TipOptionsService.send(:are_tip_options_valid?, options)).to be false
      end
    end

    property 'rejects mixed arrays' do
      forall do
        array_of(one_of([integer, string, float, boolean, nil]))
      end.check do |options|
        next if options.all? { |o| o.is_a?(Integer) }
        expect(TipOptionsService.send(:are_tip_options_valid?, options)).to be false
      end
    end

    property 'accepts empty arrays' do
      expect(TipOptionsService.send(:are_tip_options_valid?, [])).to be true
    end

    property 'accepts arrays with large integers' do
      forall do
        array_of(integer(min: -1_000_000, max: 1_000_000))
      end.check do |options|
        expect(TipOptionsService.send(:are_tip_options_valid?, options)).to be true
      end
    end
  end

  describe 'is_default_tip_option_valid?', :property_based do
    property 'accepts integers' do
      forall do
        integer
      end.check do |option|
        expect(TipOptionsService.send(:is_default_tip_option_valid?, option)).to be true
      end
    end

    property 'rejects non-integers' do
      forall do
        one_of([
          string,
          float,
          boolean,
          nil,
          array_of(integer),
          hash_of(string, integer)
        ])
      end.check do |non_integer|
        next if non_integer.is_a?(Integer)
        expect(TipOptionsService.send(:is_default_tip_option_valid?, non_integer)).to be false
      end
    end

    property 'accepts large integers' do
      forall do
        integer(min: -1_000_000, max: 1_000_000)
      end.check do |option|
        expect(TipOptionsService.send(:is_default_tip_option_valid?, option)).to be true
      end
    end

    property 'accepts zero' do
      expect(TipOptionsService.send(:is_default_tip_option_valid?, 0)).to be true
    end

    property 'accepts negative integers' do
      forall do
        integer(min: -1_000, max: -1)
      end.check do |option|
        expect(TipOptionsService.send(:is_default_tip_option_valid?, option)).to be true
      end
    end
  end

  describe 'set_tip_options', :property_based do
    property 'raises ArgumentError for invalid options' do
      forall do
        one_of([
          string,
          integer,
          float,
          boolean,
          nil,
          array_of(string),
          array_of(float),
          array_of(boolean),
          array_of(nil)
        ])
      end.check do |invalid_options|
        next if TipOptionsService.send(:are_tip_options_valid?, invalid_options)
        expect { TipOptionsService.set_tip_options(invalid_options) }.to raise_error(ArgumentError)
      end
    end

    property 'does not raise for valid options' do
      forall do
        array_of(integer)
      end.check do |valid_options|
        # Mock Redis to avoid actual database calls
        allow($redis).to receive(:set)
        expect { TipOptionsService.set_tip_options(valid_options) }.not_to raise_error
      end
    end
  end

  describe 'set_default_tip_option', :property_based do
    property 'raises ArgumentError for invalid options' do
      forall do
        one_of([
          string,
          float,
          boolean,
          nil,
          array_of(integer),
          hash_of(string, integer)
        ])
      end.check do |invalid_option|
        next if TipOptionsService.send(:is_default_tip_option_valid?, invalid_option)
        expect { TipOptionsService.set_default_tip_option(invalid_option) }.to raise_error(ArgumentError)
      end
    end

    property 'does not raise for valid options' do
      forall do
        integer
      end.check do |valid_option|
        # Mock Redis to avoid actual database calls
        allow($redis).to receive(:set)
        expect { TipOptionsService.set_default_tip_option(valid_option) }.not_to raise_error
      end
    end
  end
end
