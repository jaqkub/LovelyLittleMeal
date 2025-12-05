# Configure Redis SSL for Action Cable on Heroku
# Heroku Redis uses SSL (rediss://) and requires SSL verification to be disabled
# This is safe because Heroku manages the Redis infrastructure and certificates
if Rails.env.production? && ENV["REDIS_URL"].present?
  # Parse the Redis URL to check if it uses SSL
  redis_url = URI.parse(ENV["REDIS_URL"])
  
  # If using SSL (rediss://), configure SSL parameters for the Redis client
  if redis_url.scheme == "rediss"
    # Monkey-patch the Redis class to automatically handle SSL verification
    # for rediss:// URLs. This ensures all Redis connections (including Action Cable)
    # will use SSL without verification when connecting to Heroku Redis
    # We patch it early in the initialization process to catch all Redis connections
    require "redis"
    
    # Log that we're configuring SSL (helpful for debugging)
    Rails.logger.info("Configuring Redis SSL for Heroku (rediss://) - disabling certificate verification")
    
    Redis.class_eval do
      # Store the original initialize method
      unless method_defined?(:original_initialize)
        alias_method :original_initialize, :initialize
      end
      
      # Override initialize to add SSL configuration for rediss:// URLs
      def initialize(options = {})
        # Normalize options to a hash
        opts = case options
        when String
          # Redis.new("redis://...")
          { url: options }
        when Hash
          # Redis.new(url: "...") or Redis.new({ url: "..." })
          options.dup
        else
          # Redis.new() with no args
          {}
        end
        
        # Check if URL contains rediss:// (either as string or in hash)
        url = opts[:url] || opts["url"] || (options.is_a?(String) ? options : nil)
        
        # If we have a rediss:// URL, add SSL params to disable verification
        if url && url.to_s.start_with?("rediss://")
          opts[:ssl_params] ||= {}
          opts[:ssl_params] = opts[:ssl_params].dup if opts[:ssl_params].frozen?
          opts[:ssl_params][:verify_mode] = OpenSSL::SSL::VERIFY_NONE
        end
        
        # Call the original initialize with modified options
        original_initialize(opts)
      end
    end
  end
end

