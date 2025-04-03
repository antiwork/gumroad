# frozen_string_literal: true

require "spec_helper"

describe InstallmentSearchService do
  describe "#process" do
    it "can filter by seller" do
      product_1 = create(:product)
      installment_1 = create(:installment, link: product_1)
      installment_2 = create(:installment, link: product_1)
      creator_1 = product_1.user
      product_2 = create(:product)
      installment_3 = create(:installment, link: product_2)
      creator_2 = product_2.user
      create(:installment)
      index_model_records(Installment)
      expect(get_records(seller: creator_1)).to match_array([installment_1, installment_2])
      expect(get_records(seller: [creator_1, creator_2])).to match_array([installment_1, installment_2, installment_3])
    end

    it "can exclude deleted posts" do
      installment_1 = create(:installment)
      installment_2 = create(:installment, deleted_at: Time.current)
      index_model_records(Installment)
      expect(get_records(exclude_deleted: false)).to match_array([installment_1, installment_2])
      expect(get_records(exclude_deleted: true)).to match_array([installment_1])
    end

    it "filters by type to only include the specified posts" do
      installment_1 = create(:installment)
      installment_2 = create(:scheduled_installment)
      installment_3 = create(:published_installment)
      index_model_records(Installment)
      expect(get_records(type: nil)).to match_array([installment_1, installment_2, installment_3])
      expect(get_records(type: "draft")).to match_array([installment_1])
      expect(get_records(type: "scheduled")).to match_array([installment_2])
      expect(get_records(type: "published")).to match_array([installment_3])
    end

    it "can exclude workflow posts" do
      workflow = create(:workflow)
      workflow_installment = create(:installment, workflow:)
      installment = create(:installment)
      index_model_records(Installment)
      expect(get_records(exclude_workflow_installments: false)).to match_array([workflow_installment, installment])
      expect(get_records(exclude_workflow_installments: true)).to match_array([installment])
    end

    it "can apply some native ES params" do
      installment = create(:installment)
      create(:installment, created_at: 1.day.ago)
      index_model_records(Installment)
      response = described_class.new(sort: { created_at: :asc }, from: 1, size: 1).process
      expect(response.results.total).to eq(2)
      expect(response.records.load).to match_array([installment])
    end

    it "supports fulltext/autocomplete search" do
      installment_1 = create(:installment, name: "The Gumroad Journey Beginning", message: "<p>Lorem ipsum dolor</p>")
      installment_2 = create(:installment, name: "My First Sale Went Live!", message: "<p>Lor ipsum dolor</p>")
      installment_3 = create(:installment, name: "Reached 100 followers!", message: "<p>Lorem dol</p>")
      installment_4 = create(:installment, name: "Reached 1000 followers!", message: "<p>Lo dolor</p>")
      index_model_records(Installment)
      expect(get_records(q: "gum")).to match_array([installment_1])
      expect(get_records(q: "ipsum")).to match_array([installment_1, installment_2])
      expect(get_records(q: "followers")).to match_array([installment_3, installment_4])
      expect(get_records(q: "live")).to match_array([installment_2])
      expect(get_records(q: "dolor")).to match_array([installment_1, installment_2, installment_4])
      # test support for exact search beyond max_ngram
      expect(get_records(q: "The Gumroad Journey Beginning")).to match_array([installment_1])
      # test support for exact title search wth different case
      expect(get_records(q: "the gumroad journey beginning")).to match_array([installment_1])
      # test scoring
      expect(get_records(q: "Lo dolor")).to eq([installment_4, installment_1, installment_2])
    end
  end

  describe ".search" do
    it "is a shortcut to initialization + process" do
      result_double = double
      options = { a: 1, b: 2 }
      instance_double = double(process: result_double)
      expect(described_class).to receive(:new).with(options).and_return(instance_double)
      expect(described_class.search(options)).to eq(result_double)
    end
  end

  def get_records(options)
    described_class.new(options).process.records.load
  end
end
