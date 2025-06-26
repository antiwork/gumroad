# frozen_string_literal: true

require 'rails_helper'
require 'prop_check'

RSpec.describe JsonValidator, type: :validator do
  include PropCheck::RSpec

  let(:validator) { described_class.new(schema: schema) }
  let(:record) { double('record', errors: double('errors', add: nil)) }

  describe 'validate_each', :property_based do
    context 'with string schema' do
      let(:schema) { { type: 'string' } }

      property 'accepts valid strings' do
        forall do
          string
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-strings' do
        forall do
          one_of([integer, float, boolean, nil, array_of(integer), hash_of(string, integer)])
        end.check do |value|
          next if value.is_a?(String)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with integer schema' do
      let(:schema) { { type: 'integer' } }

      property 'accepts valid integers' do
        forall do
          integer
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-integers' do
        forall do
          one_of([string, float, boolean, nil, array_of(integer), hash_of(string, integer)])
        end.check do |value|
          next if value.is_a?(Integer)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with number schema' do
      let(:schema) { { type: 'number' } }

      property 'accepts valid numbers' do
        forall do
          one_of([integer, float])
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-numbers' do
        forall do
          one_of([string, boolean, nil, array_of(integer), hash_of(string, integer)])
        end.check do |value|
          next if value.is_a?(Numeric)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with boolean schema' do
      let(:schema) { { type: 'boolean' } }

      property 'accepts valid booleans' do
        forall do
          boolean
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-booleans' do
        forall do
          one_of([string, integer, float, nil, array_of(integer), hash_of(string, integer)])
        end.check do |value|
          next if value.is_a?(TrueClass) || value.is_a?(FalseClass)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with array schema' do
      let(:schema) { { type: 'array', items: { type: 'integer' } } }

      property 'accepts arrays of integers' do
        forall do
          array_of(integer)
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects arrays with non-integer elements' do
        forall do
          array_of(one_of([string, float, boolean, nil]))
        end.check do |value|
          next if value.all? { |item| item.is_a?(Integer) }
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end

      property 'rejects non-arrays' do
        forall do
          one_of([string, integer, float, boolean, nil, hash_of(string, integer)])
        end.check do |value|
          next if value.is_a?(Array)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with object schema' do
      let(:schema) { { type: 'object', properties: { name: { type: 'string' }, age: { type: 'integer' } } } }

      property 'accepts valid objects' do
        forall do
          hash_of(string, one_of([string, integer]))
        end.check do |value|
          next unless value.is_a?(Hash) && value.all? { |k, v| k.is_a?(String) && (v.is_a?(String) || v.is_a?(Integer)) }
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-objects' do
        forall do
          one_of([string, integer, float, boolean, nil, array_of(integer)])
        end.check do |value|
          next if value.is_a?(Hash)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with enum schema' do
      let(:schema) { { enum: ['red', 'green', 'blue'] } }

      property 'accepts enum values' do
        forall do
          one_of(['red', 'green', 'blue'])
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects non-enum values' do
        forall do
          one_of(['yellow', 'purple', 'orange', integer, float, boolean, nil])
        end.check do |value|
          next if ['red', 'green', 'blue'].include?(value)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with minimum/maximum constraints' do
      let(:schema) { { type: 'integer', minimum: 0, maximum: 100 } }

      property 'accepts values within range' do
        forall do
          integer(min: 0, max: 100)
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects values outside range' do
        forall do
          one_of([
            integer(min: -1000, max: -1),
            integer(min: 101, max: 1000),
            string,
            float,
            boolean,
            nil
          ])
        end.check do |value|
          next if value.is_a?(Integer) && value >= 0 && value <= 100
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with pattern constraint' do
      let(:schema) { { type: 'string', pattern: '^[a-z]+$' } }

      property 'accepts strings matching pattern' do
        forall do
          string_of(character(min: 'a', max: 'z'))
        end.check do |value|
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects strings not matching pattern' do
        forall do
          one_of([
            string_of(character(min: 'A', max: 'Z')),
            string_of(character(min: '0', max: '9')),
            string_of(one_of(['!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '-', '_', '+', '='])),
            integer,
            float,
            boolean,
            nil
          ])
        end.check do |value|
          next if value.is_a?(String) && value.match?(/^[a-z]+$/)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end

    context 'with required properties' do
      let(:schema) { { type: 'object', properties: { name: { type: 'string' }, age: { type: 'integer' } }, required: ['name'] } }

      property 'accepts objects with required properties' do
        forall do
          hash_of(string, one_of([string, integer]))
        end.check do |value|
          next unless value.is_a?(Hash) && value.key?('name') && value['name'].is_a?(String)
          expect { validator.validate_each(record, :field, value) }.not_to change { record.errors }
        end
      end

      property 'rejects objects missing required properties' do
        forall do
          hash_of(string, one_of([string, integer]))
        end.check do |value|
          next if value.is_a?(Hash) && value.key?('name') && value['name'].is_a?(String)
          expect(record.errors).to receive(:add).with(:field, anything)
          validator.validate_each(record, :field, value)
        end
      end
    end
  end
end
