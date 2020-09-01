# OpenID Connect Authentication for Redmine
# Copyright (C) 2020 Contargo GmbH & Co. KG
#
class OidcSession
  include ActiveModel::Model
  include ActiveModel::Serialization

  attr_accessor :session, :state, :nonce, :code, :session_state
  attr_accessor :id_token, :access_token, :refresh_token

  SESSION_KEY = :oidc_session

  def self.spawn(session)
    if session[SESSION_KEY].present?
      new(session[SESSION_KEY].merge({session: session}))
    else
      new(session: session)
    end
  end

  def authorization_endpoint
    oidc_client.authorization_uri(
      nonce: oidc_nonce,
      state: oidc_nonce,
      scope: oidc_scope,
    )
  end

  def end_session_endpoint
    return if oidc_config.end_session_endpoint.nil?
    oidc_config.end_session_endpoint + '?' + end_session_query.to_param
  end

  def update!(params)
    @session_state = params[:session_state]
    @code = params[:code]
    save!
  end

  def acquire!
    oidc_client.authorization_code = @code
    parse(oidc_client.access_token!)
  end

  def refresh!
    oidc_client.refresh_token = @refresh_token
    parse(oidc_client.access_token!)
  end

  def destroy!
    session.delete(SESSION_KEY)
  end

  def complete?
    @id_token.present?
  end

  def verify!
    decoded_tokens[:id].verify!(
      issuer: settings.issuer_url,
      client_id: settings.client_id,
      nonce: oidc_nonce,
    )
  end

  def oidc_identifier
    @oidc_indentifier ||= decoded_tokens[:id].raw_attributes[settings.unique_id_claim]
  end

  def user_attributes
    attributes = decoded_tokens[:id].raw_attributes
    {
      oidc_identifier: oidc_identifier,
      login: attributes['preferred_username'],
      firstname: attributes['given_name'],
      lastname: attributes['family_name'],
      mail: attributes['email'],
      admin: roles.include?(realm_admin_role),
    }
  end

  def authorized?
    not realm_access_roles.disjoint?(roles)
  end

  def save!
    @session[SESSION_KEY] = self.serializable_hash
  end

  private

  def parse(access_token)
    @access_token = access_token.access_token
    @refresh_token = access_token.refresh_token
    @id_token = access_token.id_token
    save!
  end

  def roles
    @roles ||= decoded_tokens[:access].raw_attributes['realm_access']['roles'].map(&:downcase).to_set
  end

  def realm_access_roles
    @realm_access_roles ||= settings.realm_access_roles.parse_csv.map(&:downcase).map(&:strip).to_set
  end

  def realm_admin_role
    @realm_admin_role ||= settings.realm_admin_role.strip.downcase
  end

  def decoded_tokens
    @decoded_tokens ||= {
      access: decode_token(@access_token),
      id: decode_token(@id_token),
    }
  end

  def end_session_query
    query = {
      'session_state' => @session_state,
      'post_logout_redirect_uri' => routes.oidc_local_logout_url,
    }
    if @id_token.present?
      query['id_token_hint'] = id_token
    end
    query
  end

  def oidc_client
    @oidc_client ||= OpenIDConnect::Client.new(
        identifier: settings.client_id,
        secret: settings.client_secret,
        authorization_endpoint: oidc_config.authorization_endpoint,
        token_endpoint: oidc_config.token_endpoint,
        userinfo_endpoint: oidc_config.userinfo_endpoint,
        jwks_uri: oidc_config.jwks_uri,
        scopes_supported: oidc_config.scopes_supported,
        redirect_uri: routes.oidc_callback_url,
    )
  end

  def oidc_scope
    scope = oidc_config.scopes_supported & [:openid, :email, :profile, :address].collect(&:to_s)
    @scope ||= scope & settings.scope.split unless (settings.scope.nil? || settings.scope.empty?)
  end

  def decode_token(token)
    raise Exception unless token.present?
    OpenIDConnect::ResponseObject::IdToken.decode(token, oidc_config.jwks)
  end

  def oidc_config
    @oidc_config ||= OpenIDConnect::Discovery::Provider::Config.discover! settings.issuer_url
  rescue OpenIDConnect::Discovery::DiscoveryFailed => e
  end

  def oidc_nonce
    if !@nonce
      @nonce = SecureRandom.uuid
      save!
    end
    @nonce
  end

  def settings
    @settings ||= RedmineOidc.settings
  end

  def routes
    @routes ||= Rails.application.routes.url_helpers
  end

  def attributes
    {
      'state' => nil,
      'nonce' => nil,
      'code' => nil,
      'session_state' => nil,
      'id_token' => nil,
      'access_token' => nil,
      'refresh_token' => nil,
    }
  end

end