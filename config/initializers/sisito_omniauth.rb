if Rails.application.config.sisito.dig(:omniauth, :google_client_id)
  Rails.application.config.middleware.use OmniAuth::Builder do
    omniauth = Rails.application.config.sisito.fetch(:omniauth)

    provider_options = {provider_ignores_state: true}
    provider_options[:hd] = Array(omniauth[:hd]) if omniauth[:hd]

    provider :google_oauth2,
      omniauth.fetch(:google_client_id),
      omniauth.fetch(:google_client_secret),
      provider_options
  end

  # Build the OAuth callback URL from a fixed host instead of the forgeable
  # Host / X-Forwarded-Host headers (GHSA-m27g-v28p-f9fx, CVE-2026-63183).
  if (full_host = Rails.application.config.sisito.dig(:omniauth, :full_host))
    OmniAuth.config.full_host = full_host
  end

  OmniAuth.config.on_failure = Proc.new do |env|
    OmniAuth::FailureEndpoint.new(env).redirect_to_failure
  end
end
