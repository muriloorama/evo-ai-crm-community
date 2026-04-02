require 'rails_helper'

RSpec.describe ConfigTest::BmsTestService do
  subject { described_class.new.call }

  describe '#call' do
    context 'when API key is not configured' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return(nil)
      end

      it 'returns failure' do
        expect(subject).to eq({ success: false, message: 'BMS API key not configured' })
      end
    end

    context 'when API key is blank' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('')
      end

      it 'returns failure' do
        expect(subject).to eq({ success: false, message: 'BMS API key not configured' })
      end
    end

    context 'when API key is valid' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('valid-key')

        response = instance_double(Net::HTTPResponse, code: '200')
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
      end

      it 'returns success' do
        expect(subject).to eq({ success: true, message: 'BMS API connection successful' })
      end
    end

    context 'when API key is invalid (401)' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('invalid-key')

        response = instance_double(Net::HTTPResponse, code: '401')
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
      end

      it 'returns failure with invalid key message' do
        expect(subject).to eq({ success: false, message: 'BMS API key is invalid or expired' })
      end
    end

    context 'when API key is forbidden (403)' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('forbidden-key')

        response = instance_double(Net::HTTPResponse, code: '403')
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
      end

      it 'returns failure with invalid key message' do
        expect(subject).to eq({ success: false, message: 'BMS API key is invalid or expired' })
      end
    end

    context 'when API key is valid but payload rejected (400)' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('valid-key')

        response = instance_double(Net::HTTPResponse, code: '400')
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
      end

      it 'returns success since key was accepted' do
        expect(subject).to eq({ success: true, message: 'BMS API connection successful' })
      end
    end

    context 'when API returns server error (500)' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('valid-key')

        response = instance_double(Net::HTTPResponse, code: '500')
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)
      end

      it 'returns failure with HTTP code' do
        expect(subject).to eq({ success: false, message: 'BMS API returned HTTP 500' })
      end
    end

    context 'when connection times out' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('valid-key')

        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Timeout::Error)
      end

      it 'returns failure with timeout message' do
        expect(subject).to eq({ success: false, message: 'BMS API connection timed out after 15 seconds' })
      end
    end

    context 'when an unexpected error occurs' do
      before do
        allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('valid-key')

        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(StandardError.new('Network error'))
      end

      it 'returns failure with error message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('BMS connection failed')
      end
    end
  end
end
