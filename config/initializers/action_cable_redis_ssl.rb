# Configure Redis SSL for Action Cable on Heroku
# Heroku Redis uses SSL (rediss://) and requires SSL verification to be disabled
# This is safe because Heroku manages the Redis infrastructure and certificates
if Rails.env.production? && ENV["REDIS_URL"].present?
  # Parse the Redis URL to check if it uses SSL
  redis_url = URI.parse(ENV["REDIS_URL"])
  
  # If using SSL (rediss://), configure SSL parameters for the Redis client
  if redis_url.scheme == "rediss"
    # Configure Action Cable's Redis adapter to use SSL without verification
    # This is necessary because Heroku Redis uses self-signed certificates
    # in the certificate chain that cause verification to fail
    # We do this by monkey-patching the Redis connector used by Action Cable
    require "action_cable/subscription_adapter/redis"
    
    # Override the redis_connector method in Action Cable's Redis adapter
    # This method is called when creating the Redis connection for Action Cable
    ActionCable::SubscriptionAdapter::Redis.class_eval do
      # Store the original redis_connector if it exists
      alias_method :original_redis_connector, :redis_connector if method_defined?(:redis_connector)
      
      private
      
      # Override redis_connector to add SSL configuration for Heroku Redis
      def redis_connector
        ->(config) do
          # Get the Redis URL from config
          url = config[:url] || config["url"] || ENV["REDIS_URL"]
          
          # Parse the URL to check if it's SSL
          uri = URI.parse(url)
          
          if uri.scheme == "rediss"
            # Configure Redis client with SSL verification disabled
            # This is safe for Heroku Redis as Heroku manages the infrastructure
            Redis.new(
              url: url,
              ssl_params: {
                verify_mode: OpenSSL::SSL::VERIFY_NONE
              }
            )
          else
            # Non-SSL connection - use default Redis client
            Redis.new(url: url)
          end
        end
      end
    end
  end
end

