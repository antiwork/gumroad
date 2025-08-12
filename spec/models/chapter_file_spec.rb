# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChapterFile, type: :model do
  describe 'validations' do
    it 'validates presence of product_file and url' do
      chapter_file = ChapterFile.new
      expect(chapter_file.valid?).to be_falsey
      expect(chapter_file.errors[:product_file]).to include("can't be blank")
      expect(chapter_file.errors[:url]).to include("can't be blank")
    end

    it 'validates file type is .vtt' do
      product_file = create(:product_file)
      chapter_file = ChapterFile.new(product_file: product_file, url: 'https://example.com/file.txt')
      expect(chapter_file.valid?).to be_falsey
      expect(chapter_file.errors[:base]).to include("Chapter file type not supported. Please upload only WebVTT files with extension .vtt.")
    end

    it 'accepts valid .vtt files' do
      product_file = create(:product_file)
      chapter_file = ChapterFile.new(product_file: product_file, url: 'https://example.com/chapters.vtt')
      expect(chapter_file.valid?).to be_truthy
    end
  end

  describe 'associations' do
    it 'belongs to product_file' do
      expect(ChapterFile.reflect_on_association(:product_file).macro).to eq(:belongs_to)
    end
  end

  describe 'scopes' do
    it 'has alive scope' do
      expect(ChapterFile).to respond_to(:alive)
    end
  end
end
