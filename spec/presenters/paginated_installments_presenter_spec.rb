# frozen_string_literal: true

describe PaginatedInstallmentsPresenter do
  describe "#props" do
    let(:seller) { create(:user) }
    let!(:published_installment1) { create(:installment, name: "Exciting offer - Email 1", seller:, published_at: 2.days.ago) }
    let!(:published_installment2) { create(:installment, name: "Hello world!", seller:, published_at: 1.day.ago) }
    let!(:draft_installment) { create(:installment, name: "Exciting offer - Email 3", seller:) }
    let(:type) { "published" }
    let(:page) { nil }
    let(:query) { nil }
    let(:presenter) { described_class.new(seller:, type:, page:, query:) }

    before do
      stub_const("#{described_class}::PER_PAGE", 1)
    end

    context "when 'page' option is not specified" do
      it "returns paginated installments for the first page" do
        result = presenter.props

        expect(result[:pagination]).to eq(count: 2, next: 2)
        expect(result[:installments].sole).to eq(InstallmentPresenter.new(seller:, installment: published_installment2).props)
        expect(result[:has_posts]).to be(true)
      end
    end

    context "when 'page' option is specified" do
      let(:page) { 2 }

      it "returns paginated installments for the specified page" do
        result = presenter.props

        expect(result[:pagination]).to eq(count: 2, next: nil)
        expect(result[:installments].sole).to eq(InstallmentPresenter.new(seller:, installment: published_installment1).props)
      end
    end

    context "when the specified 'page' option is an overflowing page number" do
      let(:page) { 3 }

      it "returns an empty page" do
        result = presenter.props

        expect(result[:pagination]).to eq(count: 2, next: nil)
        expect(result[:installments]).to be_empty
      end
    end

    context "when 'type' is 'scheduled'" do
      let(:type) { "scheduled" }
      let(:scheduled_installment1) { create(:installment, seller:, ready_to_publish: true) }
      let!(:scheduled_installment1_rule) { create(:installment_rule, installment: scheduled_installment1, to_be_published_at: 3.days.from_now.to_date + 4.hours) }
      let(:scheduled_installment2) { create(:installment, seller:, ready_to_publish: true) }
      let!(:scheduled_installment2_rule) { create(:installment_rule, installment: scheduled_installment2, to_be_published_at: 1.days.from_now.to_date + 2.hours) }
      let(:scheduled_installment3) { create(:installment, seller:, ready_to_publish: true) }
      let!(:scheduled_installment3_rule) { create(:installment_rule, installment: scheduled_installment3, to_be_published_at: 1.day.from_now.to_date + 10.hours) }

      before do
        stub_const("#{described_class}::PER_PAGE", 10)
      end

      it "returns scheduled installments ordered by 'to_be_published_at' earliest first" do
        result = presenter.props

        expect(result[:pagination]).to eq(count: 3, next: nil)
        expect(result[:installments]).to eq([
                                              InstallmentPresenter.new(seller:, installment: scheduled_installment2).props,
                                              InstallmentPresenter.new(seller:, installment: scheduled_installment3).props,
                                              InstallmentPresenter.new(seller:, installment: scheduled_installment1).props,
                                            ])
      end
    end

    context "when the specified 'type' option is invalid" do
      let(:type) { "invalid" }

      it "raises an error" do
        expect { presenter.props }.to raise_error(ArgumentError, "Invalid type")
      end
    end

    context "when seller has no installments" do
      let(:seller_without_installments) { create(:user) }
      let(:presenter) { described_class.new(seller: seller_without_installments, type:, page:, query:) }

      it "returns has_posts as false" do
        result = presenter.props

        expect(result[:has_posts]).to be(false)
      end
    end

    context "when a non-nil 'query' option is specified" do
      let!(:published_installment3) { create(:installment, name: "Exciting offer - Email 2", seller:, published_at: 3.days.ago) }
      let(:query) { "offer" }

      before do
        index_model_records(Installment)
      end

      it "returns paginated installments for the specified query for the first page" do
        expect(InstallmentSearchService).to receive(:search).with({
                                                                    exclude_deleted: true,
                                                                    type:,
                                                                    exclude_workflow_installments: true,
                                                                    seller:,
                                                                    q: query,
                                                                    fields: %w[name message],
                                                                    from: 0,
                                                                    size: 1,
                                                                    sort: [:_score, { created_at: :desc }, { id: :desc }]
                                                                  }).and_call_original

        result = presenter.props

        expect(result[:pagination]).to eq(count: 2, next: 2)
        expect(result[:installments].sole).to eq(InstallmentPresenter.new(seller:, installment: published_installment3).props)
      end

      context "when 'page' option is specified" do
        let(:page) { 2 }

        it "returns paginated installments for the specified query for the specified page" do
          expect(InstallmentSearchService).to receive(:search).with({
                                                                      exclude_deleted: true,
                                                                      type:,
                                                                      exclude_workflow_installments: true,
                                                                      seller:,
                                                                      q: query,
                                                                      fields: %w[name message],
                                                                      from: 1,
                                                                      size: 1,
                                                                      sort: [:_score, { created_at: :desc }, { id: :desc }]
                                                                    }).and_call_original

          result = presenter.props

          expect(result[:pagination]).to eq(count: 2, next: nil)
          expect(result[:installments].sole).to eq(InstallmentPresenter.new(seller:, installment: published_installment1).props)
        end
      end
    end
  end
end
