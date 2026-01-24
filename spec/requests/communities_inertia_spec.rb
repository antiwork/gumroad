# frozen_string_literal: true

require 'rails_helper'

describe 'Communities Inertia Endpoints', type: :request do
  let(:user) { create(:user) }
  let!(:community) { create(:community, seller: user) }

  before { sign_in user }

  it 'renders Inertia component for /communities' do
    get '/communities'
    expect(response).to be_successful
    expect(response.headers['Vary']).to include('Accept')
    expect(response.body).to include('Communities/Index')
  end

  it 'renders Inertia component for /communities/:community_id' do
    get "/communities/#{community.external_id}"
    expect(response).to be_successful
    expect(response.headers['Vary']).to include('Accept')
    expect(response.body).to include('Communities/Show')
  end
end
