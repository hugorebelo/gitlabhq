# frozen_string_literal: true

require 'spec_helper'

describe Gitlab::HTTP do
  include StubRequests

  context 'when allow_local_requests' do
    it 'sends the request to the correct URI' do
      stub_full_request('https://example.org:8080', ip_address: '8.8.8.8').to_return(status: 200)

      described_class.get('https://example.org:8080', allow_local_requests: false)

      expect(WebMock).to have_requested(:get, 'https://8.8.8.8:8080').once
    end
  end

  context 'when not allow_local_requests' do
    it 'sends the request to the correct URI' do
      stub_full_request('https://example.org:8080')

      described_class.get('https://example.org:8080', allow_local_requests: true)

      expect(WebMock).to have_requested(:get, 'https://8.8.8.9:8080').once
    end
  end

  describe 'allow_local_requests_from_web_hooks_and_services is' do
    before do
      WebMock.stub_request(:get, /.*/).to_return(status: 200, body: 'Success')
    end

    context 'disabled' do
      before do
        allow(Gitlab::CurrentSettings).to receive(:allow_local_requests_from_web_hooks_and_services?).and_return(false)
      end

      it 'deny requests to localhost' do
        expect { described_class.get('http://localhost:3003') }.to raise_error(Gitlab::HTTP::BlockedUrlError)
      end

      it 'deny requests to private network' do
        expect { described_class.get('http://192.168.1.2:3003') }.to raise_error(Gitlab::HTTP::BlockedUrlError)
      end

      context 'if allow_local_requests set to true' do
        it 'override the global value and allow requests to localhost or private network' do
          stub_full_request('http://localhost:3003')

          expect { described_class.get('http://localhost:3003', allow_local_requests: true) }.not_to raise_error
        end
      end
    end

    context 'enabled' do
      before do
        allow(Gitlab::CurrentSettings).to receive(:allow_local_requests_from_web_hooks_and_services?).and_return(true)
      end

      it 'allow requests to localhost' do
        stub_full_request('http://localhost:3003')

        expect { described_class.get('http://localhost:3003') }.not_to raise_error
      end

      it 'allow requests to private network' do
        expect { described_class.get('http://192.168.1.2:3003') }.not_to raise_error
      end

      context 'if allow_local_requests set to false' do
        it 'override the global value and ban requests to localhost or private network' do
          expect { described_class.get('http://localhost:3003', allow_local_requests: false) }.to raise_error(Gitlab::HTTP::BlockedUrlError)
        end
      end
    end
  end

  describe 'handle redirect loops' do
    before do
      stub_full_request("http://example.org", method: :any).to_raise(HTTParty::RedirectionTooDeep.new("Redirection Too Deep"))
    end

    it 'handles GET requests' do
      expect { described_class.get('http://example.org') }.to raise_error(Gitlab::HTTP::RedirectionTooDeep)
    end

    it 'handles POST requests' do
      expect { described_class.post('http://example.org') }.to raise_error(Gitlab::HTTP::RedirectionTooDeep)
    end

    it 'handles PUT requests' do
      expect { described_class.put('http://example.org') }.to raise_error(Gitlab::HTTP::RedirectionTooDeep)
    end

    it 'handles DELETE requests' do
      expect { described_class.delete('http://example.org') }.to raise_error(Gitlab::HTTP::RedirectionTooDeep)
    end

    it 'handles HEAD requests' do
      expect { described_class.head('http://example.org') }.to raise_error(Gitlab::HTTP::RedirectionTooDeep)
    end
  end

  describe '.try_get' do
    let(:path) { 'http://example.org' }

    let(:extra_log_info_proc) do
      proc do |error, url, options|
        { klass: error.class, url: url, options: options }
      end
    end

    let(:request_options) do
      {
        verify: false,
        basic_auth: { username: 'user', password: 'pass' }
      }
    end

    described_class::HTTP_ERRORS.each do |exception_class|
      context "with #{exception_class}" do
        let(:klass) { exception_class }

        context 'with path' do
          before do
            expect(described_class).to receive(:get)
              .with(path, {})
              .and_raise(klass)
          end

          it 'handles requests without extra_log_info' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), {})

            expect(described_class.try_get(path)).to be_nil
          end

          it 'handles requests with extra_log_info as hash' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { a: :b })

            expect(described_class.try_get(path, extra_log_info: { a: :b })).to be_nil
          end

          it 'handles requests with extra_log_info as proc' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { url: path, klass: klass, options: {} })

            expect(described_class.try_get(path, extra_log_info: extra_log_info_proc)).to be_nil
          end
        end

        context 'with path and options' do
          before do
            expect(described_class).to receive(:get)
              .with(path, request_options)
              .and_raise(klass)
          end

          it 'handles requests without extra_log_info' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), {})

            expect(described_class.try_get(path, request_options)).to be_nil
          end

          it 'handles requests with extra_log_info as hash' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { a: :b })

            expect(described_class.try_get(path, **request_options, extra_log_info: { a: :b })).to be_nil
          end

          it 'handles requests with extra_log_info as proc' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { klass: klass, url: path, options: request_options })

            expect(described_class.try_get(path, **request_options, extra_log_info: extra_log_info_proc)).to be_nil
          end
        end

        context 'with path, options, and block' do
          let(:block) do
            proc {}
          end

          before do
            expect(described_class).to receive(:get)
              .with(path, request_options, &block)
              .and_raise(klass)
          end

          it 'handles requests without extra_log_info' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), {})

            expect(described_class.try_get(path, request_options, &block)).to be_nil
          end

          it 'handles requests with extra_log_info as hash' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { a: :b })

            expect(described_class.try_get(path, **request_options, extra_log_info: { a: :b }, &block)).to be_nil
          end

          it 'handles requests with extra_log_info as proc' do
            expect(Gitlab::ErrorTracking)
              .to receive(:log_exception)
              .with(instance_of(klass), { klass: klass, url: path, options: request_options })

            expect(described_class.try_get(path, **request_options, extra_log_info: extra_log_info_proc, &block)).to be_nil
          end
        end
      end
    end
  end
end