require "spec_helper"

RSpec.describe ElasticsearchSetup do
  describe ".recreate_index" do
    subject(:recreate_index) { described_class.recreate_index(model) }

    let(:indices_proxy) { instance_double("IndicesProxy") }
    let(:elasticsearch_proxy) { instance_double("ElasticsearchProxy", delete_index!: true) }
    let(:model) { double("Model", index_name: "link-test", __elasticsearch__: elasticsearch_proxy) }

    before do
      allow(EsClient).to receive(:indices).and_return(indices_proxy)
    end

    it "treats index already exists errors as success when the index is present" do
      allow(elasticsearch_proxy).to receive(:create_index!).and_raise(
        Elasticsearch::Transport::Transport::Errors::BadRequest.new("resource_already_exists_exception")
      )
      allow(indices_proxy).to receive(:exists?).with(index: "link-test").and_return(true)

      expect { recreate_index }.not_to raise_error
      expect(elasticsearch_proxy).to have_received(:delete_index!).with(force: true).once
      expect(indices_proxy).to have_received(:exists?).with(index: "link-test").once
    end

    it "retries until the index exists" do
      allow(elasticsearch_proxy).to receive(:create_index!).and_return(nil, nil)
      allow(indices_proxy).to receive(:exists?).with(index: "link-test").and_return(false, true)
      allow(described_class).to receive(:sleep)

      expect { recreate_index }.not_to raise_error
      expect(elasticsearch_proxy).to have_received(:delete_index!).with(force: true).twice
      expect(described_class).to have_received(:sleep).with(0.1).once
    end
  end
end
