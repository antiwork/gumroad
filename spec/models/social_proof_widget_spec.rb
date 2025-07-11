require 'rails_helper'

RSpec.describe SocialProofWidget, type: :model do
  describe 'validations' do
    let(:user) { create(:user) }

    it 'is valid with valid attributes' do
      widget = build(:social_proof_widget, user: user)
      expect(widget).to be_valid
    end

    it 'requires a name' do
      widget = build(:social_proof_widget, user: user, name: nil)
      expect(widget).not_to be_valid
      expect(widget.errors[:name]).to include("can't be blank")
    end

    it 'requires a title' do
      widget = build(:social_proof_widget, user: user, title: nil)
      expect(widget).not_to be_valid
      expect(widget.errors[:title]).to include("can't be blank")
    end

    describe 'icon_name validation' do
      context 'when image_type is icon' do
        it 'accepts valid icon names' do
          valid_icon = SocialProofWidget.available_icons.first
          widget = build(:social_proof_widget, user: user, image_type: 'icon', icon_name: valid_icon)
          expect(widget).to be_valid
        end

        it 'rejects invalid icon names' do
          widget = build(:social_proof_widget, user: user, image_type: 'icon', icon_name: 'invalid-icon')
          expect(widget).not_to be_valid
          expect(widget.errors[:icon_name]).to include('invalid-icon is not a valid icon name')
        end

        it 'requires an icon_name' do
          widget = build(:social_proof_widget, user: user, image_type: 'icon', icon_name: nil)
          expect(widget).not_to be_valid
          expect(widget.errors[:icon_name]).to include("can't be blank")
        end
      end

      context 'when image_type is not icon' do
        it 'does not validate icon_name' do
          widget = build(:social_proof_widget, user: user, image_type: 'none', icon_name: 'invalid-icon')
          expect(widget).to be_valid
        end
      end
    end
  end

  describe '.available_icons' do
    it 'returns an array of available icon names' do
      icons = SocialProofWidget.available_icons
      expect(icons).to be_an(Array)
      expect(icons).to include('heart-fill')
      expect(icons).to include('star-fill')
      expect(icons).to include('gift-fill')
    end

    it 'returns sorted icon names' do
      icons = SocialProofWidget.available_icons
      expect(icons).to eq(icons.sort)
    end

    it 'caches the result' do
      expect(Dir).to receive(:entries).once.and_call_original
      SocialProofWidget.available_icons
      SocialProofWidget.available_icons
    end
  end
end
