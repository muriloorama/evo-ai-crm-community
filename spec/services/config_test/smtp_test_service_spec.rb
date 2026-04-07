require 'rails_helper'

RSpec.describe ConfigTest::SmtpTestService do
  subject { described_class.new.call }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SMTP_ADDRESS', anything).and_return('smtp.example.com')
    allow(GlobalConfigService).to receive(:load).with('SMTP_PORT', anything).and_return('587')
    allow(GlobalConfigService).to receive(:load).with('SMTP_USERNAME', anything).and_return('user@example.com')
    allow(GlobalConfigService).to receive(:load).with('SMTP_PASSWORD_SECRET', anything).and_return('secret123')
    allow(GlobalConfigService).to receive(:load).with('SMTP_DOMAIN', anything).and_return('example.com')
    allow(GlobalConfigService).to receive(:load).with('SMTP_AUTHENTICATION', anything).and_return('login')
    allow(GlobalConfigService).to receive(:load).with('SMTP_ENABLE_STARTTLS_AUTO', anything).and_return('true')
  end

  describe '#call' do
    context 'when SMTP connection succeeds' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).with('smtp.example.com', 587).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_yield(smtp)
      end

      it 'returns success' do
        expect(subject).to eq({ success: true, message: 'SMTP connection successful' })
      end
    end

    context 'when authentication fails' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(Net::SMTPAuthenticationError.new('535 Authentication failed'))
      end

      it 'returns failure with auth error message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Authentication failed')
      end
    end

    context 'when server is busy' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(Net::SMTPServerBusy.new('421 Server busy'))
      end

      it 'returns failure with busy message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Server busy')
      end
    end

    context 'when connection times out' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(Timeout::Error)
      end

      it 'returns failure with timeout message' do
        expect(subject).to eq({ success: false, message: 'Connection timed out after 15 seconds' })
      end
    end

    context 'when connection is refused' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(Errno::ECONNREFUSED)
      end

      it 'returns failure with connection refused message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Connection refused')
      end
    end

    context 'when hostname cannot be resolved' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(SocketError.new('getaddrinfo: Name or service not known'))
      end

      it 'returns failure with hostname error' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Could not resolve hostname')
      end
    end

    context 'when an unexpected error occurs' do
      before do
        smtp = instance_double(Net::SMTP)
        allow(Net::SMTP).to receive(:new).and_return(smtp)
        allow(smtp).to receive(:open_timeout=)
        allow(smtp).to receive(:read_timeout=)
        allow(smtp).to receive(:enable_starttls_auto)
        allow(smtp).to receive(:start).and_raise(StandardError.new('Something went wrong'))
      end

      it 'returns failure with generic error' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Connection failed')
      end
    end

    context 'timeout configuration' do
      it 'sets 15-second timeout' do
        expect(described_class::TIMEOUT).to eq(15)
      end
    end
  end
end
