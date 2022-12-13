# name: discourse-onesignal
# about: Push notifications via the OneSignal API.
# version: 2.0
# authors: pmusaraj
# url: https://github.com/pmusaraj/discourse-onesignal

enabled_site_setting :onesignal_push_enabled

register_asset 'stylesheets/common/app-login.scss'
register_asset 'stylesheets/mobile/app-login.scss', :mobile

load File.expand_path('lib/discourse-onesignal/engine.rb', __dir__)

after_initialize do
  ONESIGNALAPI = 'https://onesignal.com/api/v1/notifications'

  User.class_eval do
    has_many :onesignal_subscriptions, dependent: :delete_all
  end

  DiscourseEvent.on(:post_notification_alert) do |user, payload|

    if SiteSetting.onesignal_app_id.nil? || SiteSetting.onesignal_app_id.empty?
      Rails.logger.warn('OneSignal App ID is missing')
    end
    if SiteSetting.onesignal_rest_api_key.nil? || SiteSetting.onesignal_rest_api_key.empty?
      Rails.logger.warn('OneSignal REST API Key is missing')
    end

    # legacy, no longer used
    clients = user.user_api_keys
        .where("('push' = ANY(scopes) OR 'notifications' = ANY(scopes)) AND push_url IS NOT NULL AND position(push_url in ?) > 0 AND revoked_at IS NULL",
                  ONESIGNALAPI)
        .pluck(:client_id, :push_url)

    if user.onesignal_subscriptions.exists? || clients.length > 0
      Jobs.enqueue(:onesignal_pushnotification, payload: payload, username: user.username)
    end
  end

  module ::Jobs
    class OnesignalPushnotification < ::Jobs::Base
      def execute(args)
        payload = args["payload"]

        params = {
          "app_id" => SiteSetting.onesignal_app_id,
          "contents" => {"en" => "#{payload[:username]}: #{payload[:excerpt]}"},
          "headings" => {"en" => payload[:topic_title]},
          "data" => {"discourse_url" => payload[:post_url]},
          "small_icon" => SiteSetting.onesignal_notification_icon,
          "huawei_small_icon" => SiteSetting.onesignal_notification_icon,
          "ios_badgeType" => "Increase",
          "ios_badgeCount" => "1",
          "filters" => [
              {"field": "tag", "key": "username", "relation": "=", "value": args["username"]},
            ]
        }

        uri = URI.parse(ONESIGNALAPI)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if uri.scheme == 'https'

        request = Net::HTTP::Post.new(uri.path,
            'Content-Type'  => 'application/json;charset=utf-8',
            'Authorization' => "Basic #{SiteSetting.onesignal_rest_api_key}")
        request.body = params.as_json.to_json
        response = http.request(request)

        case response
        when Net::HTTPSuccess then
          Rails.logger.info("Push notification sent via OneSignal to #{args['username']}.")
        else
          Rails.logger.error("OneSignal error when sending a push notification")
          Rails.logger.error("#{request.to_yaml}")
          Rails.logger.error("#{response.to_yaml}")
        end

      end
    end
  end
end
