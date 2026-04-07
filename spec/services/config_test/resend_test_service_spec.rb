require 'rails_helper'

RSpec.describe ConfigTest::ResendTestService do
  subject { described_class.new.call }

  describe '#call' do
    context 'when API key is not configured' do
      before do
        allow(GlobalConfigService).to receive(:load).with('RESEND_API_SECRET', anything).and_return(nil)
      end

      it 'returns failure' do
        expect(subject).to eq({ success: false, message: 'Resend API key not configured' })
      end
    end

    context 'when API key is blank' do
      before do
        allow(GlobalConfigService).to receive(:load).with('RESEND_API_SECRET', anything).and_return('')
      end

      it 'returns failure' do
        expect(subject).to eq({ success: false, message: 'Resend API key not configured' })
      end
    end

    context 'when API key is valid' do
      before do
        allow(GlobalConfigService).to receive(:load).with('RESEND_API_SECRET', anything).and_return('re_valid_key')

        domains = instance_double('Resend::Domains')
        client = instance_double(Resend::Client, domains: domains)
        allow(Resend::Client).to receive(:new).with(api_key: 're_valid_key').and_return(client)
        allow(domains).to receive(:list).and_return([])
      end

      it 'returns success' do
        expect(subject).to eq({ success: true, message: 'Resend API connection successful' })
      end
    end

    context 'when API key is invalid' do
      before do
        allow(GlobalConfigService).to receive(:load).with('RESEND_API_SECRET', anything).and_return('re_invalid_key')

        client = instance_double(Resend::Client)
        domains = instance_double('Resend::Domains')
        allow(Resend::Client).to receive(:new).and_return(client)
        allow(client).to receive(:domains).and_return(domains)
        allow(domains).to receive(:list).and_raise(Resend::Error.new('Invalid API key'))
      end

      it 'returns failure with Resend error' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Resend API error')
      end
    end

    context 'when an unexpected error occurs' do
      before do
        allow(GlobalConfigService).to receive(:load).with('RESEND_API_SECRET', anything).and_return('re_valid_key')
        allow(Resend::Client).to receive(:new).and_raise(StandardError.new('Connection error'))
      end

      it 'returns failure with generic error' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Resend connection failed')
      end
    end
  end
end
