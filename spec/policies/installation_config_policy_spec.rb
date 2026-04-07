require 'rails_helper'

RSpec.describe InstallationConfigPolicy, type: :policy do
  let(:record) { :installation_config }

  describe '#manage?' do
    context 'when user is an administrator (SuperAdmin)' do
      let(:user) { instance_double('User', administrator?: true, has_permission?: false) }
      let(:policy) { described_class.new({ user: user, account: nil }, record) }

      it 'returns true' do
        expect(policy.manage?).to be true
      end
    end

    context 'when user has installation_configs.manage permission' do
      let(:user) { instance_double('User', administrator?: false) }
      let(:policy) { described_class.new({ user: user, account: nil }, record) }

      before do
        allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(true)
      end

      it 'returns true' do
        expect(policy.manage?).to be true
      end
    end

    context 'when user is not admin and lacks permission' do
      let(:user) { instance_double('User', administrator?: false) }
      let(:policy) { described_class.new({ user: user, account: nil }, record) }

      before do
        allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(false)
      end

      it 'returns false' do
        expect(policy.manage?).to be false
      end
    end

    context 'when user is nil' do
      let(:policy) { described_class.new({ user: nil, account: nil }, record) }

      it 'returns falsy' do
        expect(policy.manage?).to be_falsey
      end
    end
  end

  describe 'CRUD methods delegate to manage?' do
    let(:user) { instance_double('User', administrator?: true, has_permission?: false) }
    let(:policy) { described_class.new({ user: user, account: nil }, record) }

    %i[index? show? create? update? destroy?].each do |method|
      it "#{method} delegates to manage?" do
        expect(policy.send(method)).to eq(policy.manage?)
      end
    end
  end
end
