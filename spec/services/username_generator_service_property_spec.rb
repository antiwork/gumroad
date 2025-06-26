# frozen_string_literal: true

require 'rails_helper'
require 'prop_check'

RSpec.describe UsernameGeneratorService, type: :service do
  include PropCheck::RSpec

  describe 'ensure_valid_username', :property_based do
    let(:service) { described_class.new(double('user')) }

    property 'always returns a string between 3 and 20 characters' do
      forall do
        string
      end.check do |input|
        result = service.send(:ensure_valid_username, input)
        expect(result).to be_a(String)
        expect(result.length).to be >= 3
        expect(result.length).to be <= 20
      end
    end

    property 'always returns lowercase alphanumeric characters only' do
      forall do
        string
      end.check do |input|
        result = service.send(:ensure_valid_username, input)
        expect(result).to match(/^[a-z0-9]+$/)
      end
    end

    property 'always contains at least one letter' do
      forall do
        string
      end.check do |input|
        result = service.send(:ensure_valid_username, input)
        expect(result).to match(/[a-z]/)
      end
    end

    property 'never returns a username from DENYLIST' do
      forall do
        string
      end.check do |input|
        result = service.send(:ensure_valid_username, input)
        expect(DENYLIST).not_to include(result)
      end
    end

    property 'handles empty strings by adding a letter' do
      result = service.send(:ensure_valid_username, '')
      expect(result).to match(/^[a-z][a-z0-9]*$/)
      expect(result.length).to be >= 3
    end

    property 'handles strings with only numbers by adding a letter' do
      forall do
        string_of(character(min: '0', max: '9'), min: 1, max: 10)
      end.check do |numbers_only|
        result = service.send(:ensure_valid_username, numbers_only)
        expect(result).to match(/^[a-z][a-z0-9]*$/)
        expect(result.length).to be >= 3
      end
    end

    property 'handles strings with only special characters by adding a letter' do
      forall do
        string_of(one_of(['!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '-', '_', '+', '=']))
      end.check do |special_chars|
        result = service.send(:ensure_valid_username, special_chars)
        expect(result).to match(/^[a-z][a-z0-9]*$/)
        expect(result.length).to be >= 3
      end
    end

    property 'handles mixed case by converting to lowercase' do
      forall do
        string_of(one_of([
          character(min: 'A', max: 'Z'),
          character(min: 'a', max: 'z'),
          character(min: '0', max: '9')
        ]))
      end.check do |mixed_case|
        result = service.send(:ensure_valid_username, mixed_case)
        expect(result).to eq(result.downcase)
      end
    end

    property 'handles strings longer than 20 characters by truncating' do
      forall do
        string(min: 21, max: 50)
      end.check do |long_string|
        result = service.send(:ensure_valid_username, long_string)
        expect(result.length).to be <= 20
      end
    end

    property 'handles strings shorter than 3 characters by padding' do
      forall do
        string(min: 0, max: 2)
      end.check do |short_string|
        result = service.send(:ensure_valid_username, short_string)
        expect(result.length).to be >= 3
      end
    end

    property 'preserves valid alphanumeric characters' do
      forall do
        string_of(one_of([
          character(min: 'a', max: 'z'),
          character(min: '0', max: '9')
        ]), min: 3, max: 20)
      end.check do |valid_string|
        result = service.send(:ensure_valid_username, valid_string)
        # The result should contain the original valid characters (possibly with additions)
        valid_string.chars.each do |char|
          expect(result).to include(char)
        end
      end
    end

    property 'handles strings that are exactly in DENYLIST' do
      DENYLIST.each do |denied_name|
        result = service.send(:ensure_valid_username, denied_name)
        expect(result).not_to eq(denied_name)
        expect(result).to match(/^[a-z0-9]+$/)
        expect(result.length).to be >= 3
        expect(result.length).to be <= 20
      end
    end

    property 'handles strings that start with numbers' do
      forall do
        string_of(character(min: '0', max: '9'), min: 1, max: 5) +
        string_of(character(min: 'a', max: 'z'), min: 1, max: 5)
      end.check do |number_starting_string|
        result = service.send(:ensure_valid_username, number_starting_string)
        expect(result).to match(/^[a-z][a-z0-9]*$/)
      end
    end

    property 'handles strings with spaces and special characters' do
      forall do
        string_of(one_of([
          character(min: 'a', max: 'z'),
          character(min: 'A', max: 'Z'),
          character(min: '0', max: '9'),
          ' ',
          '!',
          '@',
          '#',
          '$',
          '%',
          '^',
          '&',
          '*',
          '(',
          ')',
          '-',
          '_',
          '+',
          '='
        ]))
      end.check do |mixed_string|
        result = service.send(:ensure_valid_username, mixed_string)
        expect(result).to match(/^[a-z0-9]+$/)
        expect(result.length).to be >= 3
        expect(result.length).to be <= 20
      end
    end

    property 'is idempotent for already valid usernames' do
      forall do
        string_of(character(min: 'a', max: 'z'), min: 3, max: 20)
      end.check do |valid_username|
        next if DENYLIST.include?(valid_username)
        result1 = service.send(:ensure_valid_username, valid_username)
        result2 = service.send(:ensure_valid_username, result1)
        expect(result1).to eq(result2)
      end
    end
  end

  describe 'random_digit', :property_based do
    let(:service) { described_class.new(double('user')) }

    property 'always returns a single digit string' do
      forall do
        integer(min: 1, max: 100)
      end.check do |_|
        result = service.send(:random_digit)
        expect(result).to be_a(String)
        expect(result.length).to eq(1)
        expect(result).to match(/^[0-9]$/)
      end
    end

    property 'returns digits between 0 and 8' do
      forall do
        integer(min: 1, max: 100)
      end.check do |_|
        result = service.send(:random_digit).to_i
        expect(result).to be >= 0
        expect(result).to be <= 8
      end
    end
  end
end
