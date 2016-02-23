require 'spec_helper'
describe Spaceship::Client do
  class TestClient < Spaceship::Client
    def self.hostname
      "http://example.com"
    end

    def req_home
      request(:get, TestClient.hostname)
    end

    def send_login_request(_user, _password)
      true
    end
  end

  let(:subject) { TestClient.new }
  let(:time_out_error) { Faraday::Error::TimeoutError.new }
  let(:unauth_error) { Spaceship::Client::UnauthorizedAccessError.new }
  let(:test_uri) { "http://example.com" }

  let(:default_body) { '{foo: "bar"}' }

  def stub_client_request(error, times, status, body)
    stub_request(:get, test_uri).
      to_raise(error).times(times).then.
      to_return(status: status, body: body)
  end

  def stub_client_retry_auth(status_error, times, status_ok, body)
    stub_request(:get, test_uri).
      to_return(status: status_error, body: body).times(times).
      then.to_return(status: status_ok, body: body)
  end

  describe 'retry' do
    it "re-raises Timeout exception when retry limit reached" do
      stub_client_request(time_out_error, 6, 200, nil)

      expect do
        subject.req_home
      end.to raise_error(time_out_error)
    end

    it "retries when AppleTimeoutError error raised" do
      stub_client_request(time_out_error, 2, 200, default_body)

      expect(subject.req_home.body).to eq(default_body)
    end

    it "raises AppleTimeoutError when response contains '302 Found'" do
      stub_connection_timeout_302

      expect do
        subject.req_home
      end.to raise_error(Spaceship::Client::AppleTimeoutError)
    end

    it "successfully retries request after logging in again when UnauthorizedAccess Error raised" do
      subject.login
      stub_client_retry_auth(401, 1, 200, default_body)

      expect(subject.req_home.body).to eq(default_body)
    end

    it "fails to retry request if loggin fails in retry block when UnauthorizedAccess Error raised" do
      subject.login
      stub_client_retry_auth(401, 1, 200, default_body)

      # the next login will fail
      def subject.send_login_request(_user, _password)
        raise Spaceship::Client::UnauthorizedAccessError.new, "Faked"
      end

      expect do
        subject.req_home
      end.to raise_error(Spaceship::Client::UnauthorizedAccessError)
    end

    describe "retry when user and password not fetched from CredentialManager" do
      let(:the_user) { 'u' }
      let(:the_password) { 'p' }

      it "is able to retry and login successfully" do
        def subject.send_login_request(user, password)
          can_login = (user == 'u' && password == 'p')
          raise Spaceship::Client::UnauthorizedAccessError.new, "Faked" unless can_login
          true
        end

        subject.login(the_user, the_password)

        stub_client_retry_auth(401, 1, 200, default_body)

        expect(subject.req_home.body).to eq(default_body)
      end
    end
  end

  describe "SSL ciphers", run_on_ci: false do
    class SSLValidatorClient < Spaceship::Client
      def self.hostname
        "https://www.howsmyssl.com"
      end
    end

    let(:client) { SSLValidatorClient.new }
    before { WebMock.allow_net_connect! }
    after { WebMock.disable_net_connect! }

    it 'doesn\'t use weak ciphers when secured' do
      json = client.send('request', :get, 'a/check').body
      # Bad ?
      expect(json['insecure_cipher_suites']).to eq({})
      # improvable ?
      expect(json['tls_version']).to eq('TLS 1.2')
      expect(json['ephemeral_keys_supported']).to eq(true)
      expect(json['session_ticket_supported']).to eq(true)
      # Probably Okay
      expect(json['rating']).to eq('Probably Okay')
    end
  end
end
