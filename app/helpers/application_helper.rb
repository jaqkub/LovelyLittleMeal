module ApplicationHelper
  # Generates absolute URL for Active Storage attachments (required for OG tags)
  #
  # @param attachment [ActiveStorage::Attached::One] The attached file
  # @return [String] Absolute URL to the attachment
  def absolute_url_for(attachment)
    return nil unless attachment&.attached?
    
    # Use rails_blob_url which always generates absolute URLs
    # In production with Cloudinary, this will use the Cloudinary CDN URL
    # In development with local storage, this will use the app's host
    rails_blob_url(attachment)
  end

  # Generates absolute URL for files in public directory (required for OG tags)
  #
  # @param path [String] Path relative to public directory (e.g., "llm-og-logo.svg")
  # @return [String] Absolute URL to the file
  def public_file_url(path)
    # Remove leading slash if present
    path = path.sub(/^\//, '')
    # Generate absolute URL using request base URL
    "#{request.base_url}/#{path}"
  end

  # Returns the appropriate logo format for OG images
  # Uses PNG for social media crawlers (WhatsApp, Facebook, Twitter, etc.) that don't support SVG
  # Uses SVG for regular browsers and modern platforms
  #
  # @return [String] Absolute URL to the logo (PNG for social bots, SVG otherwise)
  def og_logo_url
    # List of social media crawler user agents that don't support SVG
    # These platforms require PNG/JPG for Open Graph images
    social_crawlers = [
      'WhatsApp',           # WhatsApp link preview
      'facebookexternalhit', # Facebook crawler
      'Facebot',            # Facebook crawler (alternative)
      'Twitterbot',         # Twitter/X crawler
      'LinkedInBot',       # LinkedIn crawler
      'Slackbot',           # Slack link preview
      'SkypeUriPreview',   # Skype link preview
      'TelegramBot',        # Telegram link preview
      'Applebot',           # Apple iMessage link preview
      'Discordbot',         # Discord embed
      'Googlebot',          # Google (may not support SVG in OG tags)
      'bingbot'             # Bing crawler
    ]

    # Check if the current request is from a social media crawler
    user_agent = request.user_agent.to_s
    is_social_crawler = social_crawlers.any? { |crawler| user_agent.include?(crawler) }

    # Use PNG for social media crawlers, SVG for regular browsers
    logo_file = is_social_crawler ? 'llm-og-logo.png' : 'llm-og-logo.svg'
    public_file_url(logo_file)
  end
end
