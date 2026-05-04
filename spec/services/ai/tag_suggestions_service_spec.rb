require 'spec_helper'

RSpec.describe Ai::TagSuggestionsService do
  let(:seller) { create(:user) }
  let(:service) { described_class.new(current_seller: seller) }

  describe '#generate_tags' do
    it 'returns an array of tag strings' do
      tags = service.generate_tags(product_name: 'Design System Kit')
      
      expect(tags).to be_an(Array)
      expect(tags.length).to be_between(5, 7)
      expect(tags).to all(be_a(String))
    end

    it 'returns different tags on subsequent calls' do
      tags1 = service.generate_tags(product_name: 'Design System Kit')
      tags2 = service.generate_tags(product_name: 'Design System Kit')
      
      expect(tags1).not_to eq(tags2)
    end
  end
end
