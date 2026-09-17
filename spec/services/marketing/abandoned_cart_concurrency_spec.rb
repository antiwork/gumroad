# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Marketing::AbandonedCart, "concurrent changes" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    create(:payment_completed, user: @seller)
  end

  after do
    @seller.workflows.each do |workflow|
      workflow.installments.each do |email|
        email.installment_rule&.destroy!
        email.destroy!
      end
      workflow.destroy!
    end
    @seller.payments.destroy_all
    @seller.links.each(&:destroy!)
    @seller.destroy!
  end

  def service
    described_class.new(product: Link.find(@product.id), seller: User.find(@seller.id))
  end

  it "serializes two enables with independent connections and the same reviewed token" do
    token = service.state[:activation_token]
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          cart = service
          ready << true
          Timeout.timeout(10) { start.pop }
          cart.enable(expected_activation_token: token).id
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start << true }
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(@seller.workflows.alive.abandoned_cart_type.published.count).to eq(1)
    expect(@seller.workflows.sole.installments.alive.count).to eq(1)
  ensure
    threads&.each { _1.join(15) }
  end

  %i[enable pause].each do |operation|
    it "rechecks scope after an editor commits between discovery and #{operation}" do
      workflow = service.enable
      workflow.unpublish! if operation == :enable
      other = create(:product, user: @seller)
      discovered = Queue.new
      proceed = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          cart = service
          intercepted = false
          allow(cart).to receive(:covering_workflows).and_wrap_original do |original|
            snapshot = original.call
            unless intercepted
              intercepted = true
              discovered << true
              Timeout.timeout(10) { proceed.pop }
            end
            snapshot
          end
          cart.public_send(operation)
        end
      end
      Timeout.timeout(10) { discovered.pop }
      Workflow.find(workflow.id).with_lock do
        Workflow.find(workflow.id).update!(bought_products: [@product.unique_permalink, other.unique_permalink])
      end
      proceed << true
      expect(thread.value).to eq(:stale)
      expect(workflow.reload.published_at.present?).to eq(operation == :pause)
    ensure
      proceed << true if proceed
      thread&.join(15)
    end
  end

  it "does not publish a workflow deleted after discovery" do
    workflow = service.enable
    workflow.unpublish!
    cart = service
    intercepted = false
    allow(cart).to receive(:can_toggle?).and_wrap_original do |original|
      snapshot = original.call
      unless intercepted
        intercepted = true
        Workflow.find(workflow.id).mark_deleted!
      end
      snapshot
    end
    expect(cart.enable).to eq(:stale)
    expect(workflow.reload.published_at).to be_nil
  end
end
